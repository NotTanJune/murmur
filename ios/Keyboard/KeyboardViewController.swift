import MurmurDesign
import MurmurKit
import OSLog
import SwiftUI
import UIKit

/// The keyboard extension's entry point. It owns what only a view controller has (the text
/// proxy, the globe key's event handling, the responder chain, the height constraint) and the
/// key plane; the strip and the panels live in `KeyboardView`, and what the keys do to the text
/// in `TypingController`.
///
/// The key plane is a direct subview of the root view, above the SwiftUI hosting view and
/// pinned to the bottom. Touches on the keys go from UIKit's hit test to `KeyPlaneView` to the
/// controller, with no SwiftUI view or gesture recognizer in between.
final class KeyboardViewController: UIInputViewController {
    private let microphone = WebMicrophone()
    /// The keyboard's height: the key page's, computed from the width at each layout. The emoji
    /// and history panels use the same height, because iOS ignores a keyboard that grows after
    /// it first appears.
    private var heightConstraint: NSLayoutConstraint?
    /// The key plane: the keyboard's height less the strip, set at each layout.
    private let plane = KeyPlaneView()
    private var planeHeightConstraint: NSLayoutConstraint?
    private lazy var dictation = KeyboardDictation(
        microphone: microphone,
        proxy: { [weak self] in self?.textDocumentProxy }
    )
    private lazy var typing = TypingController(proxy: { [weak self] in self?.textDocumentProxy })
    private static let log = Logger(subsystem: "ai.pivotstudio.murmur", category: "keyboard")
    private static let typingLog = Logger(subsystem: "ai.pivotstudio.murmur", category: "typing")
    /// The gesture recognizers already relaxed, so each is changed and logged once.
    private var relaxedRecognizers = Set<ObjectIdentifier>()

    /// The environment must be configured before anything reads storage or `Settings.shared`.
    /// Nothing the stored properties above create does; `dictation` is lazy.
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        PhoneEnvironment.configure()
        RunLog.prepare()
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        PhoneEnvironment.configure()
        RunLog.prepare()
        super.init(coder: coder)
    }

    /// The primary view is an input view that allows key clicks; without one, `playInputClick`
    /// does nothing.
    override func loadView() {
        let clicking = ClickingInputView(frame: .zero, inputViewStyle: .keyboard)
        clicking.allowsSelfSizing = true
        inputView = clicking
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        microphone.attach(to: view)
        dictation.haptics.attach(to: view)
        KeyFeedback.attach(to: view)
        typing.popupHost = view
        dictation.typingReport = { [weak self] in self?.typing.stats ?? TypingStats() }
        typing.onGlobe = { [weak self] button, event in self?.handleInputModeList(from: button, with: event) }
        // Dictation types through the same shift state as the keys, and tells the controller
        // what it typed so the shift key and the strip follow.
        dictation.takeShift = { [weak self] in self?.typing.takeShiftForDictation() ?? false }
        dictation.onTextInserted = { [weak self] in self?.typing.noteDictationInserted() }
        let host = UIHostingController(rootView: KeyboardView(
            dictation: dictation,
            typing: typing,
            actions: KeyboardActions(
                insert: { [weak self] in self?.typing.insertExternal($0) },
                delete: { [weak self] in self?.typing.deleteExternal() },
                openMurmur: { [weak self] in self?.openMurmur() }
            )
        ))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        // Required, as Apple's custom keyboard guide does it ("change its primary view's height
        // constraint"). It was 999 until 2026-11-22: the system also pins the input view with
        // its own required `UIView-Encapsulated-Layout-Height`, which a 999 constraint can never
        // beat. A required one conflicts with the system's while the sizes differ (UIKit logs
        // that, and it is expected). The first size is portrait's; `viewDidLayoutSubviews` sets
        // the real one from the width.
        let height = view.heightAnchor.constraint(equalToConstant: TypingController.initialHeight)
        heightConstraint = height
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
        host.didMove(toParent: self)

        // The plane goes on top of the hosting view, so a touch on a key reaches it first and
        // SwiftUI never sees it. Its popups draw on the root view's layer, above it.
        plane.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(plane)
        let planeHeight = plane.heightAnchor.constraint(equalToConstant: typing.planeHeight)
        planeHeightConstraint = planeHeight
        NSLayoutConstraint.activate([
            plane.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            plane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            plane.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            planeHeight,
        ])
        typing.attach(plane)
    }

    /// The key page's height follows the width and the orientation, so it is set at each layout.
    /// It also reports the height asked for and the height the keyboard actually has, as
    /// evidence for the Setup tab that the system honours the constraint (`KeyboardDictation`
    /// keeps only a changed pair). The shown height is the smaller of the view's and its
    /// window's, because a window shorter than the view clips it.
    ///
    /// Landscape is read from the vertical size class and not from the view's own shape: the
    /// view is wider than it is tall in portrait too.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let landscape = traitCollection.verticalSizeClass == .compact
        typing.setLayout(
            width: view.bounds.width, isLandscape: landscape, showsGlobe: needsInputModeSwitchKey)
        // The window's recognizers can appear after the first appearance; each new one is relaxed.
        relaxTouchDelays()
        let height = typing.keyboardHeight
        if heightConstraint?.constant != height {
            heightConstraint?.constant = height
        }
        if planeHeightConstraint?.constant != typing.planeHeight {
            planeHeightConstraint?.constant = typing.planeHeight
        }
        let viewHeight = view.bounds.height
        let shown = view.window.map { min(viewHeight, $0.bounds.height) } ?? viewHeight
        dictation.noteEmojiPanelHeight(requested: height, shown: shown)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Typing first: it resets the counters that the dictation's status write reports.
        typing.keyboardAppeared()
        dictation.keyboardAppeared(hasFullAccess: hasFullAccess)
        // Contact names and the owner's text replacements: words autocorrect must not undo. The
        // answer is asynchronous; the controller rebuilds its lexicon when it arrives.
        requestSupplementaryLexicon { [weak self] lexicon in
            let words = lexicon.entries.map(\.documentText)
            Task { @MainActor in self?.typing.setSystemLexicon(words) }
        }
    }

    /// iOS holds back touches near the screen's side edges while it decides whether they are
    /// its own gestures (the home and app-switch swipes), which delays the outermost keys, and
    /// a recognizer that delays touches and then recognizes cancels them for the view below. See
    /// `relaxTouchDelays`.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The proxy's traits may have been stale in `viewWillAppear`; read them again now.
        typing.keyboardDidAppear()
        relaxTouchDelays()
    }

    /// Keys went missing on a device (62 taps counted, many more typed) with 0 cancelled and a
    /// 1.6 ms slowest `handle`, so the touches were lost before the key plane saw them. The
    /// likely holder is a system gesture recognizer with `delaysTouchesBegan` that then
    /// recognizes. This walks from the key plane up through every superview to the window and
    /// asks each gesture recognizer not to delay touches (began or ended). Nothing is removed or
    /// disabled; `cancelsTouchesInView` is left as it is and logged. Each recognizer is changed
    /// once, by `ObjectIdentifier`, and logged in category `typing`: its class, its view, its
    /// `cancelsTouchesInView` and what changed. Whether iOS honours it for its own recognizers
    /// is unverified on a device.
    private func relaxTouchDelays() {
        var node: UIView? = plane
        var depth = 0
        while let current = node {
            for recognizer in current.gestureRecognizers ?? [] {
                guard relaxedRecognizers.insert(ObjectIdentifier(recognizer)).inserted else { continue }
                let beganWas = recognizer.delaysTouchesBegan
                let endedWas = recognizer.delaysTouchesEnded
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                let changes = [
                    beganWas ? "delaysTouchesBegan true to false" : nil,
                    endedWas ? "delaysTouchesEnded true to false" : nil,
                ].compactMap { $0 }
                Self.typingLog.info(
                    "gesture recognizer \(String(describing: type(of: recognizer)), privacy: .public) on \(String(describing: type(of: current)), privacy: .public) (level \(depth)): cancelsTouchesInView \(recognizer.cancelsTouchesInView), changed: \(changes.isEmpty ? "nothing, already off" : changes.joined(separator: ", "), privacy: .public)")
            }
            node = current.superview
            depth += 1
        }
    }

    /// The host changed the text, the selection or the field: shift and the strip follow it.
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        typing.textDidChange()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        typing.textDidChange()
    }

    override func viewWillDisappear(_ animated: Bool) {
        plane.cancelAllTouches()
        // Writes the status file, which carries the typing counters.
        dictation.keyboardDisappeared()
        typing.keyboardDisappeared()
        super.viewWillDisappear(animated)
    }

    /// Opens the Murmur app at its setup screen. An extension has no `UIApplication.shared`, so
    /// this finds the application object in the responder chain and calls
    /// `openURL:options:completionHandler:` on it. The old one-argument `openURL:` is not used:
    /// it is deprecated since iOS 10 and does nothing on current systems.
    /// `extensionContext.open` is the fallback if the chain holds no application, but it is
    /// documented for Today widgets and generally reports failure for a keyboard.
    private func openMurmur() {
        guard let url = URL(string: "murmur://setup") else { return }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = view
        while let current = responder {
            if current.responds(to: selector), let implementation = current.method(for: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                unsafeBitCast(implementation, to: Open.self)(current, selector, url as NSURL, [:], nil)
                return
            }
            responder = current.next
        }
        extensionContext?.open(url, completionHandler: nil)
    }
}

/// The keyboard's root view. `UIInputViewAudioFeedback` is what lets `UIDevice.playInputClick()`
/// make a sound, and only when the user has keyboard clicks on.
private final class ClickingInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
