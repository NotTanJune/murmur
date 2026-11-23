import MurmurDesign
import MurmurKit
import SwiftUI
import UIKit

/// The keyboard extension's entry point. It owns what only a view controller has (the text
/// proxy, the globe key's event handling, the responder chain); the keys live in `KeyboardView`.
final class KeyboardViewController: UIInputViewController {
    private let microphone = WebMicrophone()
    /// The keyboard's height; the emoji panel raises it and ABC puts it back.
    private var heightConstraint: NSLayoutConstraint?
    private lazy var dictation = KeyboardDictation(
        microphone: microphone,
        proxy: { [weak self] in self?.textDocumentProxy }
    )

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
        let host = UIHostingController(rootView: KeyboardView(
            dictation: dictation,
            actions: KeyboardActions(
                insert: { [weak self] in self?.textDocumentProxy.insertText($0) },
                delete: { [weak self] in self?.textDocumentProxy.deleteBackward() },
                newline: { [weak self] in self?.textDocumentProxy.insertText("\n") },
                dismiss: { [weak self] in self?.dismissKeyboard() },
                setHeight: { [weak self] in self?.setKeyboardHeight($0) },
                globe: { [weak self] view, event in self?.handleInputModeList(from: view, with: event) },
                openMurmur: { [weak self] in self?.openMurmur() },
                showsGlobe: { [weak self] in self?.needsInputModeSwitchKey ?? false },
                returnTitle: { [weak self] in Self.title(for: self?.textDocumentProxy.returnKeyType) },
                returnIsProminent: { [weak self] in Self.isProminent(self?.textDocumentProxy.returnKeyType) }
            )
        ))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        // Required, as Apple's custom keyboard guide does it ("change its primary view's height
        // constraint"). It was 999 until 2026-11-22, and the emoji panel never got taller on a
        // device: the first size the system measures honoured the 999 constraint (the key page
        // came out at 168), but the system also pins the input view with its own required
        // `UIView-Encapsulated-Layout-Height`, which a 999 constraint can never beat, so
        // changing the constant changed nothing and logged nothing. A required one conflicts
        // with the system's while the sizes differ (UIKit logs that, and it is expected) and is
        // what the guide relies on to resize the keyboard. Unverified on a device until Setup's
        // "Emoji panel" line reads 260 shown; `KeyboardView` fits whatever height arrives.
        let height = view.heightAnchor.constraint(equalToConstant: DS.Keyboard.height)
        heightConstraint = height
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
        host.didMove(toParent: self)
    }

    /// Changes the height constraint and lays it out at once, before the SwiftUI content resizes.
    private func setKeyboardHeight(_ height: CGFloat) {
        guard heightConstraint?.constant != height else { return }
        heightConstraint?.constant = height
        view.layoutIfNeeded()
    }

    /// While the emoji panel asks for more than the key page, reports the height it asked for
    /// and the height the keyboard actually has, as evidence for the Setup tab. The system can
    /// resize the keyboard a pass later than `setKeyboardHeight`, so each layout reports and
    /// `KeyboardDictation` keeps only a changed pair. The shown height is the smaller of the
    /// view's and its window's, because a window shorter than the view clips it.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let requested = heightConstraint?.constant, requested != DS.Keyboard.height else { return }
        let viewHeight = view.bounds.height
        let shown = view.window.map { min(viewHeight, $0.bounds.height) } ?? viewHeight
        dictation.noteEmojiPanelHeight(requested: requested, shown: shown)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        dictation.keyboardAppeared(hasFullAccess: hasFullAccess)
    }

    override func viewWillDisappear(_ animated: Bool) {
        dictation.keyboardDisappeared()
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

    /// Apple's keyboard turns return blue when the field gives it a job other than a new line.
    private static func isProminent(_ type: UIReturnKeyType?) -> Bool {
        switch type {
        case nil, .default?, .continue?: false
        default: true
        }
    }

    private static func title(for type: UIReturnKeyType?) -> String {
        switch type {
        case .send: "send"
        case .search, .google, .yahoo: "search"
        case .go, .route: "go"
        case .done: "done"
        case .next: "next"
        case .join: "join"
        default: "return"
        }
    }
}

/// The keyboard's root view. `UIInputViewAudioFeedback` is what lets `UIDevice.playInputClick()`
/// make a sound, and only when the user has keyboard clicks on.
private final class ClickingInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
