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
    /// Diagnostics only: logs main-thread stalls while typing diagnostics are on.
    private let stallMonitor = StallMonitor()
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
        hasDictationKey = true
    }

    /// Our own dictation is the m, so iOS need not add its microphone key under the keyboard
    /// (Apple, "Configuring a custom keyboard interface": two dictation buttons confuse). The
    /// system's microphone still showed on the owner's phone with the flag set in `viewDidLoad`,
    /// then in `init` (2026-11-25). This is the last try, by the owner's word: the flag reads
    /// true whenever the system asks, and is set again at each appearance. If the microphone
    /// still shows, iOS 26 ignores the flag (the owner has the system's dictation switched on);
    /// leave it and do not try further.
    override var hasDictationKey: Bool {
        get { true }
        set { super.hasDictationKey = true }
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
        // Never clear: a touch on a clear point of the keyboard goes to the host app and is
        // lost (see `touchBackingUIColor`). This covers the strip and the emoji and history panels.
        clicking.backgroundColor = DS.Keyboard.touchBackingUIColor
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
    /// What the keyboard's geometry depends on, to skip layout passes that change none of it.
    private struct LayoutKey: Equatable {
        var width: CGFloat
        var isLandscape: Bool
        var showsGlobe: Bool
    }

    private var lastLayout: LayoutKey?

    private struct LayoutReport: Equatable {
        var requested: CGFloat
        var shown: CGFloat
    }

    private var lastReport: LayoutReport?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let landscape = traitCollection.verticalSizeClass == .compact
        // A key's pop-up is a layer added to this view, which lays the view out again: about
        // 1.6 passes per key press (measured 2026-11-25). The geometry is only worked out again
        // when something it depends on changed.
        let geometry = LayoutKey(
            width: view.bounds.width, isLandscape: landscape, showsGlobe: needsInputModeSwitchKey)
        if geometry != lastLayout {
            lastLayout = geometry
            typing.setLayout(
                width: geometry.width, isLandscape: landscape, showsGlobe: geometry.showsGlobe)
            // The window's recognizers can appear after the first appearance; each new one is relaxed.
            relaxTouchDelays()
        }
        let height = typing.keyboardHeight
        if heightConstraint?.constant != height {
            heightConstraint?.constant = height
        }
        if planeHeightConstraint?.constant != typing.planeHeight {
            planeHeightConstraint?.constant = typing.planeHeight
        }
        let viewHeight = view.bounds.height
        let shown = view.window.map { min(viewHeight, $0.bounds.height) } ?? viewHeight
        guard LayoutReport(requested: height, shown: shown) != lastReport else { return }
        lastReport = LayoutReport(requested: height, shown: shown)
        if TypingDiagnostics.isOn {
            TypingDiagnostics.log("layout", [
                "w": Double(view.bounds.width), "h": Double(viewHeight),
                "window": Double(view.window?.bounds.height ?? 0),
            ])
        }
        dictation.noteEmojiPanelHeight(requested: height, shown: shown)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasDictationKey = true
        // The model is the process's and this controller may be a new one: its changes of state
        // go to the status file through whichever controller is on screen.
        // A turn later, because the first change comes from inside `typing.keyboardAppeared()`,
        // before the dictation side has read this appearance.
        SmartPredictions.shared.onChange = { [weak self] in
            Task { @MainActor in self?.dictation.typingStatusChanged() }
        }
        // Typing first: it resets the counters that the dictation's status write reports, and
        // starts the language model's load ahead of Bark's.
        typing.keyboardAppeared()
        dictation.keyboardAppeared(hasFullAccess: hasFullAccess)
        // Contact names and the owner's text replacements: words autocorrect must not undo. The
        // answer is asynchronous; the controller rebuilds its lexicon when it arrives.
        // The completion runs on a background queue (`com.apple.TextInput.lexicon-request`), so
        // the closure must not inherit the main actor: an inherited isolation is asserted when it
        // runs, and that assertion crashed the keyboard on every appearance on 2026-11-25.
        // UIKit declares the entries main-actor isolated, so they are read after the hop; the
        // lexicon object itself is immutable once delivered.
        requestSupplementaryLexicon { @Sendable [weak self] lexicon in
            nonisolated(unsafe) let lexicon = lexicon
            Task { @MainActor in
                self?.typing.setSystemLexicon(lexicon.entries.map(\.documentText))
            }
        }
    }

    /// iOS holds back touches near the screen's side edges while it decides whether they are
    /// its own gestures (the home and app-switch swipes), which delays the outermost keys, and
    /// a recognizer that delays touches and then recognizes cancels them for the view below. See
    /// `relaxTouchDelays`.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasDictationKey = true
        // The proxy's traits may have been stale in `viewWillAppear`; read them again now.
        typing.keyboardDidAppear()
        relaxTouchDelays()
        if let window = view.window, !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchProbe }) {
            window.addGestureRecognizer(TouchProbe())
        }
        if TypingDiagnostics.isOn {
            stallMonitor.start()
            WindowProbe.plane = plane
            WindowProbe.install()
        }
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
                // Diagnostics: report this recognizer's state changes, so a touch lost while a
                // system recognizer recognizes shows up in the live log next to it.
                recognizer.addTarget(GestureWatcher.shared, action: #selector(GestureWatcher.changed(_:)))
                // Experiment (2026-11-25): the live log showed taps that never reached the plane,
                // not even its hit test, while `_UIDoubleTapInteractionGestureRecognizer` on the
                // keyboard's `_UIHostedWindow` recognized 23 times in 138 taps. Fast typing is a
                // stream of double taps to it. It is switched off for this keyboard only, to see
                // whether the lost taps stop; the next live log decides whether this stays.
                if String(describing: type(of: recognizer)).contains("DoubleTapInteraction") {
                    recognizer.isEnabled = false
                    Self.typingLog.info("disabled \(String(describing: type(of: recognizer)), privacy: .public) on \(String(describing: type(of: current)), privacy: .public)")
                    TypingDiagnostics.log("disabled", ["cls": String(describing: type(of: recognizer))])
                }
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
        TypingDiagnostics.log("host", ["what": "textDidChange"])
        typing.textDidChange()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        TypingDiagnostics.log("host", ["what": "selectionDidChange"])
        typing.textDidChange()
    }

    override func viewWillDisappear(_ animated: Bool) {
        stallMonitor.stop()
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

/// Logs the state changes of the gesture recognizers between the key plane and its window,
/// while typing diagnostics are on. A target adds nothing to a recognizer's behaviour.
@MainActor
final class GestureWatcher: NSObject {
    static let shared = GestureWatcher()

    @objc func changed(_ recognizer: UIGestureRecognizer) {
        guard TypingDiagnostics.isOn else { return }
        let state: String = switch recognizer.state {
        case .possible: "possible"
        case .began: "began"
        case .changed: "changed"
        case .ended: "ended"
        case .cancelled: "cancelled"
        case .failed: "failed"
        @unknown default: "unknown"
        }
        TypingDiagnostics.log("gesture", [
            "cls": String(describing: type(of: recognizer)), "state": state,
            "view": recognizer.view.map { String(describing: type(of: $0)) } ?? "none",
        ])
    }
}

/// Diagnostics only: sees every touch the keyboard's window receives, whichever view it was
/// hit-tested to, and never recognizes, delays or cancels anything. A tap the live log shows
/// here but not on the plane went to another view; one it never shows did not reach this
/// process at all.
final class TouchProbe: UIGestureRecognizer {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    convenience init() { self.init(target: nil, action: nil) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if TypingDiagnostics.isOn {
            for touch in touches {
                let point = touch.location(in: view)
                TypingDiagnostics.log("window", [
                    "t": touch.timestamp, "x": Double(point.x), "y": Double(point.y),
                    "view": touch.view.map { String(describing: type(of: $0)) } ?? "none",
                    "taps": touch.tapCount,
                ])
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if numberOfTouches == 0 || touches.count == event.allTouches?.count { state = .failed }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// Diagnostics only: a display link that logs every main-thread frame gap longer than
/// `DS.Keyboard.stallThresholdSeconds`, so the live log shows whether lost taps line up with a
/// busy main thread.
@MainActor
final class StallMonitor: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        last = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0, TypingDiagnostics.isOn else { return }
        let gap = link.timestamp - last
        if gap > DS.Keyboard.stallThresholdSeconds {
            TypingDiagnostics.log("stall", ["t": last, "ms": gap * 1000])
        }
    }
}
