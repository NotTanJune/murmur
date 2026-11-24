import Foundation

/// Whether the next letter is capital. `on` is one capital and then back to `off`; `capsLock`
/// stays until shift is tapped again.
public enum ShiftState: Hashable, Sendable {
    case off
    case on
    case capsLock
}

/// How a field asks for capital letters, the keyboard's own copy of `UITextAutocapitalizationType`
/// so this module needs no UIKit. The controller maps the proxy's value onto it.
public enum AutocapMode: Hashable, Sendable {
    case none
    case words
    case sentences
    case allCharacters
}

/// The kind of field the keyboard is typing into, reduced to what typing rules care about. The
/// controller maps `UIKeyboardType` onto it.
public enum FieldKeyboardKind: Hashable, Sendable {
    case `default`
    case url
    case email
    case number
    case phone
    case webSearch
}

/// What the host field says about itself. The controller builds one from the text document
/// proxy's traits at each appearance and whenever the field changes; the rules and the learning
/// policy then read it instead of UIKit.
public struct FieldTraits: Hashable, Sendable {
    /// The field accepts autocorrection (`autocorrectionType` is not `.no`).
    public var autocorrectionAllowed: Bool
    /// The field accepts spell checking (`spellCheckingType` is not `.no`).
    public var spellCheckingAllowed: Bool
    /// A password or other secure field. Nothing typed there is ever learned or suggested.
    public var isSecure: Bool
    public var keyboardKind: FieldKeyboardKind
    public var autocapitalization: AutocapMode
    /// Smart quotes are on (`smartQuotesType` is not `.no`).
    public var smartQuotes: Bool
    /// Smart dashes are on (`smartDashesType` is not `.no`).
    public var smartDashes: Bool
    /// A word for the return key when the field names a job ("send", "go"), nil for a plain
    /// new line, which shows the `return.left` glyph.
    public var returnKeyTitle: String?

    public init(
        autocorrectionAllowed: Bool = true,
        spellCheckingAllowed: Bool = true,
        isSecure: Bool = false,
        keyboardKind: FieldKeyboardKind = .default,
        autocapitalization: AutocapMode = .sentences,
        smartQuotes: Bool = true,
        smartDashes: Bool = true,
        returnKeyTitle: String? = nil
    ) {
        self.autocorrectionAllowed = autocorrectionAllowed
        self.spellCheckingAllowed = spellCheckingAllowed
        self.isSecure = isSecure
        self.keyboardKind = keyboardKind
        self.autocapitalization = autocapitalization
        self.smartQuotes = smartQuotes
        self.smartDashes = smartDashes
        self.returnKeyTitle = returnKeyTitle
    }

    /// An ordinary text field: autocorrect, smart punctuation and sentence capitals all on.
    public static let standard = FieldTraits()
}
