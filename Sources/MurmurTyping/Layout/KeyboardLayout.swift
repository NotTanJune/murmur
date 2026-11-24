import Foundation

/// The rows of keys on each page, as the stock iOS English (US) keyboard orders them. Rows hold
/// kinds only; `KeyboardMetrics` turns them into rectangles. The order matters twice: each array
/// is left to right, and the outer array is top to bottom.
public struct KeyboardLayout: Sendable {
    /// The four rows of a page. `showsGlobe` adds the next-keyboard key to the bottom row; iOS
    /// asks a keyboard to show it only when the user has more than one keyboard enabled (or the
    /// device has no hardware globe), so the layout cannot assume it.
    public static func rows(for page: Page, showsGlobe: Bool) -> [[KeyKind]] {
        switch page {
        case .letters:
            return [
                characters("q w e r t y u i o p"),
                characters("a s d f g h j k l"),
                [.shift] + characters("z x c v b n m") + [.delete],
                bottomRow(switching: .numbers, showsGlobe: showsGlobe),
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
    /// numbers (`123`) on letters, which is why the caller names its target.
    private static func bottomRow(switching target: Page, showsGlobe: Bool) -> [KeyKind] {
        var row: [KeyKind] = [.pageSwitch(target)]
        if showsGlobe { row.append(.globe) }
        row.append(contentsOf: [.emoji, .space, .return])
        return row
    }
}
