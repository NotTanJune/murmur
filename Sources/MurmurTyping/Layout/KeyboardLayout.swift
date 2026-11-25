import Foundation

/// The rows of keys on each page, as the stock iOS English (US) keyboard orders them. Rows hold
/// kinds only; `KeyboardMetrics` turns them into rectangles. The order matters twice: each array
/// is left to right, and the outer array is top to bottom.
public struct KeyboardLayout: Sendable {
    /// The four rows of a page. `showsGlobe` adds the next-keyboard key to the bottom row; iOS
    /// asks a keyboard to show it only when the user has more than one keyboard enabled (or the
    /// device has no hardware globe), so the layout cannot assume it. `field` changes the
    /// letters page's bottom row for an email, web address or web search field, as the stock
    /// keyboard does; the other pages are the same in every field.
    public static func rows(
        for page: Page, showsGlobe: Bool, field: FieldKeyboardKind = .default
    ) -> [[KeyKind]] {
        switch page {
        case .letters:
            return [
                characters("q w e r t y u i o p"),
                characters("a s d f g h j k l"),
                [.shift] + characters("z x c v b n m") + [.delete],
                bottomRow(switching: .numbers, showsGlobe: showsGlobe, field: field),
            ]
        case .numbers:
            return [
                characters("1 2 3 4 5 6 7 8 9 0"),
                characters("- / : ; ( ) $ & @ \""),
                [.pageSwitch(.symbols)] + characters(". , ? ! '") + [.delete],
                bottomRow(switching: .letters, showsGlobe: showsGlobe),
            ]
        case .symbols:
            return [
                characters("[ ] { } # % ^ * + ="),
                characters("_ \\ | ~ < > € £ ¥ •"),
                [.pageSwitch(.numbers)] + characters(". , ? ! '") + [.delete],
                bottomRow(switching: .letters, showsGlobe: showsGlobe),
            ]
        }
    }

    /// Character keys from a space separated list, so the rows above read like the keyboard.
    private static func characters(_ list: String) -> [KeyKind] {
        list.split(separator: " ").map { .character(String($0)) }
    }

    /// The bottom row. The first key goes back to letters (`ABC`) on the two other pages and to
    /// numbers (`123`) on letters, which is why the caller names its target. Between the emoji key
    /// and return the stock keyboard puts what the field needs most: the space bar; for an email
    /// address the space bar, `@` and `.`; for a web address `.`, `/` and `.com` with no space
    /// bar, because an address has no spaces; for a web search the space bar and `.`.
    private static func bottomRow(
        switching target: Page, showsGlobe: Bool, field: FieldKeyboardKind = .default
    ) -> [KeyKind] {
        var row: [KeyKind] = [.pageSwitch(target)]
        if showsGlobe { row.append(.globe) }
        row.append(.emoji)
        switch field {
        case .email: row.append(contentsOf: [.space] + characters("@ ."))
        case .url: row.append(contentsOf: characters(". / .com"))
        case .webSearch: row.append(contentsOf: [.space] + characters("."))
        case .default, .number, .phone: row.append(.space)
        }
        row.append(.return)
        return row
    }
}
