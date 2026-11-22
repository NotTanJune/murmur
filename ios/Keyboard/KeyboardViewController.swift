import MurmurDesign
import MurmurKit
import SwiftUI
import UIKit

/// The keyboard extension's entry point. It owns what only a view controller has (the text
/// proxy, the globe key's event handling, the responder chain); the keys live in `KeyboardView`.
final class KeyboardViewController: UIInputViewController {
    private let microphone = WebMicrophone()
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
        let host = UIHostingController(rootView: KeyboardView(
            dictation: dictation,
            actions: KeyboardActions(
                insert: { [weak self] in self?.textDocumentProxy.insertText($0) },
                delete: { [weak self] in self?.textDocumentProxy.deleteBackward() },
                newline: { [weak self] in self?.textDocumentProxy.insertText("\n") },
                dismiss: { [weak self] in self?.dismissKeyboard() },
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
        // One below required, so the system's own height constraint on the keyboard's view can
        // win a conflict instead of breaking one of ours at runtime.
        let height = view.heightAnchor.constraint(equalToConstant: DS.Keyboard.height)
        height.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
        host.didMove(toParent: self)
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
