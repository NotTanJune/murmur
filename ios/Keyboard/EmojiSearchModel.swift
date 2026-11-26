import MurmurDesign
import MurmurKit
import Observation
import os
import OSLog
import UIKit

/// The semantic half of emoji search, one per process: Apple's on-device sentence embedding and
/// the table of emoji vectors built from it (`EmojiVectorStore`, cached in the App Group).
///
/// Nothing here may cost a keystroke. The embedding loads and the vectors build on a utility
/// task the first time search opens; until the table is complete, search is lexical only. The
/// load is skipped when the extension has less than `memoryNeededMB` left, and the embedding and
/// the table are dropped when the emoji panel closes (the cache file stays, so the next build is
/// a read).
final class EmojiSemantic: @unchecked Sendable {
    static let shared = EmojiSemantic()

    /// What must be left under the extension's memory limit before the embedding loads. A guess
    /// (the model's footprint in a keyboard extension is unmeasured), like the 60 MB
    /// `SmartPredictions` asks of its model.
    static let memoryNeededMB = 80.0

    let store = EmojiVectorStore(cacheURL: EmojiVectorCache.url(in: MurmurEnvironment.storageRoot))
    private let lock = NSLock()
    /// The device has no embedding, so nothing more is tried this process.
    private var missing = false
    private static let log = Logger(subsystem: "ai.pivotstudio.murmur", category: "emoji")

    private static var availableMB: Double { Double(os_proc_available_memory()) / 1_048_576 }

    /// Starts loading the embedding and building or reading the vectors, once. Returns at once.
    func start() {
        let proceed: Bool = lock.withLock {
            switch store.state {
            case .idle, .unavailable: !missing
            case .building, .ready: false
            }
        }
        guard proceed else { return }
        guard Self.availableMB > Self.memoryNeededMB else {
            Self.log.notice("emoji search stays lexical: \(Self.availableMB, privacy: .public) MB left")
            return
        }
        let store = store
        Task.detached(priority: .utility) { [weak self] in
            let begin = ContinuousClock.now
            guard let embedder = NLEmbeddingEmojiEmbedder() else {
                if let self { lock.withLock { missing = true } }
                Self.log.notice("emoji search stays lexical: no sentence embedding on this device")
                return
            }
            let state = store.prepare(with: embedder, isMemoryOK: { Self.availableMB > Self.memoryNeededMB / 2 })
            Self.log.notice("emoji vectors \(String(describing: state), privacy: .public) in \(String(describing: ContinuousClock.now - begin), privacy: .public)")
        }
    }

    /// Gives the embedding and the table back. A build in progress is left to finish (it saves
    /// checkpoints, and stopping one while another could start would run two).
    func release() {
        if case .building = store.state { return }
        store.release()
    }
}

/// What emoji search shows: the query the keys type, and the emoji for it.
///
/// Lexical results are computed on the main actor as the query changes (a few comparisons per
/// emoji, measured in the low milliseconds), so a key never waits on the embedding. The blend
/// with the embedding's part (`EmojiSearch.search(_:queryVector:vectors:)`) runs on a queue
/// `EmojiSearchModel.debounce` after the last change, and replaces the lexical list only if it
/// differs and the query has not moved on.
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
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var blendTask: Task<Void, Never>?
    @ObservationIgnored private let search = EmojiSearch.standard
    @ObservationIgnored private let queue = DispatchQueue(label: "ai.pivotstudio.murmur.emoji-search", qos: .userInitiated)

    /// What the results row lists: the results, or Frequently Used while the query is empty.
    var categories: [EmojiCatalog.Category] {
        if trimmed.isEmpty {
            return [EmojiCatalog.Category(id: "recents", title: "Frequently Used", symbol: "clock", emoji: recents)]
        }
        return [EmojiCatalog.Category(id: "results", title: "Results", symbol: "magnifyingglass", emoji: results)]
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    /// Search opened: an empty query, Frequently Used as read now, and the embedding started.
    func open() {
        query = ""
        results = []
        recents = EmojiRecents.load()
        generation += 1
        version += 1
        blendTask?.cancel()
        EmojiSemantic.shared.start()
    }

    /// Search closed.
    func close() {
        blendTask?.cancel()
        generation += 1
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
        generation += 1
        blendTask?.cancel()
        results = trimmed.isEmpty ? [] : search.search(trimmed, limit: Self.resultLimit)
        version += 1
        guard !trimmed.isEmpty, EmojiSemantic.shared.store.vectors != nil else { return }
        let ticket = generation
        let text = trimmed
        let lexical = results
        let search = search
        let store = EmojiSemantic.shared.store
        let limit = Self.resultLimit
        blendTask = Task { [weak self] in
            try? await Task.sleep(for: DS.Keyboard.emojiSearchDebounce)
            guard !Task.isCancelled, let self else { return }
            let blended: [String] = await withCheckedContinuation { continuation in
                queue.async {
                    guard let vectors = store.vectors, let vector = store.embed(text) else {
                        continuation.resume(returning: [])
                        return
                    }
                    continuation.resume(returning: search.search(text, queryVector: vector, vectors: vectors, limit: limit))
                }
            }
            // The query moved on, or the embedding gave nothing, or it agrees with the words.
            guard ticket == generation, !blended.isEmpty, blended != lexical else { return }
            results = blended
            version += 1
        }
    }
}
