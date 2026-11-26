import MurmurKit
import Observation
import UIKit

/// What emoji search shows: the query the keys type, and the emoji for it.
///
/// Results are worked out on the main actor as the query changes: a keyword match over the
/// keyboard's emoji (see `EmojiSearch`), a few milliseconds, so there is no debounce and no
/// background work.
@MainActor
@Observable
final class EmojiSearchModel {
    /// The most results shown: one row, scrolled sideways.
    static let resultLimit = 40
    /// The longest query, so a held key cannot grow it without end.
    static let queryLimit = 60

    private(set) var query = ""
    /// Base emoji for the query, best first; the grid shows the preferred skin tone of each.
    private(set) var results: [String] = []
    /// Changes whenever `results` does, for the grid's reload.
    private(set) var version = 0

    /// Called when return is pressed: the search is over.
    @ObservationIgnored var onSubmit: () -> Void = {}

    @ObservationIgnored private var recents: [String] = []
    @ObservationIgnored private let search = EmojiSearch.standard

    /// What the results row lists: the results, or Frequently Used while the query is empty.
    var categories: [EmojiCatalog.Category] {
        if trimmed.isEmpty {
            return [EmojiCatalog.Category(id: "recents", title: "Frequently Used", symbol: "clock", emoji: recents)]
        }
        return [EmojiCatalog.Category(id: "results", title: "Results", symbol: "magnifyingglass", emoji: results)]
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    /// Search opened: an empty query, and Frequently Used as read now.
    func open() {
        query = ""
        results = []
        recents = EmojiRecents.load()
        version += 1
    }

    // MARK: Keys

    func handle(_ key: TypingController.SearchKey) {
        switch key {
        case .text(let text):
            append(text)
        case .delete:
            guard !query.isEmpty else { return }
            query.removeLast()
            refresh()
        case .deleteWord:
            var characters = Array(query)
            while characters.last == " " { characters.removeLast() }
            while let last = characters.last, last != " " { characters.removeLast() }
            query = String(characters)
            refresh()
        case .submit:
            onSubmit()
        }
    }

    func clear() {
        guard !query.isEmpty else { return }
        query = ""
        refresh()
    }

    private func append(_ text: String) {
        for character in text.lowercased() {
            // No leading space and no run of spaces; a query is words.
            if character == " " && (query.isEmpty || query.last == " ") { continue }
            guard character.isLetter || character.isNumber || character == " " || character == "'" || character == "-" else { continue }
            if query.count < Self.queryLimit { query.append(character) }
        }
        refresh()
    }

    // MARK: Results

    private func refresh() {
        results = trimmed.isEmpty ? [] : search.search(trimmed, limit: Self.resultLimit)
        version += 1
    }
}
