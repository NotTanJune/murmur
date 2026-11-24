import Foundation

/// The three key pages of the keyboard. Letters is the page the keyboard opens on; numbers and
/// symbols are the two pages behind the `123` and `#+=` keys.
public enum Page: Hashable, Sendable, CaseIterable {
    case letters
    case numbers
    case symbols
}

/// What a key does. Layout and touch handling both speak in these, so the layout can be tested
/// on the Mac without any view: a view only has to draw a `KeyKind` inside a `KeyFrame`.
public enum KeyKind: Hashable, Sendable {
    /// A key that types its string. Letters are stored lowercase; the view and the touch engine
    /// apply shift, so the layout is the same on every shift state.
    case character(String)
    case shift
    case delete
    case space
    case `return`
    /// Switches to another page: `123`, `#+=` or `ABC`.
    case pageSwitch(Page)
    case emoji
    case globe

    /// The typed string when this is a character key, nil for every other kind. The hit tester
    /// uses it to look a key up in the next-letter bias and to keep that bias between letters.
    public var characterValue: String? {
        if case .character(let value) = self { return value }
        return nil
    }
}
