import Foundation
import Testing
@testable import MurmurKit

/// A stand-in for Apple's embedding: a text maps to the concepts its words belong to, so a query
/// that shares no word with an emoji can still be near it.
private struct FakeEmbedder: EmojiEmbedder {
    static let concepts: [[String]] = [
        ["laugh", "funny", "joy", "hilarious", "lol"],
        ["sleep", "tired", "yawn", "bed"],
        ["money", "cash", "dollar", "rich"],
    ]
    let revision: String
    var dimension: Int { Self.concepts.count + 1 }

    init(revision: String = "fake-1") { self.revision = revision }

    func vector(for text: String) -> [Float]? {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        var vector = [Float](repeating: 0, count: dimension)
        for (index, concept) in Self.concepts.enumerated() {
            vector[index] = Float(words.filter { concept.contains($0) }.count)
        }
        // A constant component keeps a text with no concept from being a zero vector.
        vector[Self.concepts.count] = 0.1
        return vector
    }
}

struct EmojiSearchTests {
    private let search = EmojiSearch.standard

    private func top(_ query: String, _ count: Int = 5) -> [String] {
        Array(search.search(query, limit: count))
    }

    @Test("The table has every catalogue emoji, in catalogue order")
    func tableMatchesCatalogue() {
        let catalogue = EmojiCatalog.categories.flatMap(\.emoji)
        #expect(search.entries.map(\.emoji) == catalogue)
        #expect(search.entries.allSatisfy { !$0.name.isEmpty })
    }

    @Test("Words are lowercased, split at punctuation and stemmed")
    func words() {
        #expect(EmojiSearch.words("Crying, LAUGHING!") == ["cry", "laugh"])
        #expect(EmojiSearch.words("don't") == ["dont"])
        #expect(EmojiSearch.words("hearts-eyes") == ["heart", "eye"])
        #expect(EmojiSearch.words("running") == ["run"])
        #expect(EmojiSearch.words("parties") == ["party"])
        #expect(EmojiSearch.words("kiss") == ["kiss"])
        #expect(EmojiSearch.queryWords("a thing of joy") == ["thing", "joy"])
        #expect(EmojiSearch.queryWords("the") == ["the"])
        #expect(EmojiSearch.queryWords("i am so tired") == EmojiSearch.words("tired"))
    }

    @Test("A name typed exactly comes first")
    func exactName() {
        #expect(top("fire").first == "🔥")
        #expect(top("thumbs up").first == "👍")
        #expect(top("rocket").first == "🚀")
        #expect(top("face with tears of joy").first == "😂")
    }

    @Test("Keywords find an emoji the name does not")
    func keywords() {
        #expect(top("facepalm").contains("🤦"))
        #expect(top("lol").contains("😂"))
    }

    @Test("A plural, an -ing form and a case difference find the same emoji")
    func stemming() {
        #expect(top("Hearts", 8).contains("❤️"))
        #expect(top("crying", 8).contains("😭"))
        #expect(top("CRYING", 8) == top("crying", 8))
    }

    @Test("The last word may be a prefix, an earlier one may not")
    func prefix() {
        #expect(top("sunglas").contains("😎"))
        // "sungl" is not a whole word, so with another word after it nothing matches by it.
        #expect(search.lexicalHits("sungl zzzz").isEmpty)
    }

    @Test("An emoji that matches more of the words ranks above one that matches fewer")
    func multiWord() {
        let hits = search.lexicalHits("heart eyes").map { search.entries[$0.index].emoji }
        #expect(hits.prefix(3).contains("😍"))
        let both = hits.firstIndex(of: "😍")!
        let one = hits.firstIndex(of: "❤️")!
        #expect(both < one)
    }

    @Test("Nothing, or only punctuation, finds nothing")
    func emptyQueries() {
        #expect(search.search("").isEmpty)
        #expect(search.search("   ").isEmpty)
        #expect(search.search("!?").isEmpty)
        #expect(search.search("qzxqzxqzx").isEmpty)
    }

    @Test("Scores are between 0 and 1 and the whole name scores highest")
    func scores() {
        let hits = search.lexicalHits("fire")
        #expect(hits.allSatisfy { $0.score > 0 && $0.score <= 1 })
        #expect(search.entries[hits[0].index].emoji == "🔥")
        #expect(hits[0].score > hits[1].score)
    }

    @Test("Common emoji win a tie between equal matches")
    func popularTies() {
        #expect(top("heart").first == "❤️")
        #expect(top("lol", 3).contains("😂"))
        #expect(top("car").contains("🚗"))
    }

    @Test("Every emoji of the popularity list is in the catalogue")
    func popularListIsCatalogue() {
        let catalogue = Set(search.entries.map(\.emoji))
        for emoji in EmojiSearch.popular { #expect(catalogue.contains(emoji), "\(emoji)") }
        #expect(Set(EmojiSearch.popular).count == EmojiSearch.popular.count)
    }

    @Test("The limit applies")
    func limit() {
        #expect(search.search("face", limit: 7).count == 7)
    }

    // MARK: Semantic

    private func vectors(for embedder: some EmojiEmbedder) -> EmojiVectors {
        let store = EmojiVectorStore(search: search, cacheURL: nil)
        store.prepare(with: embedder)
        return store.vectors!
    }

    @Test("A query with no word in common is answered by meaning once vectors exist")
    func semanticFills() {
        let embedder = FakeEmbedder()
        let table = vectors(for: embedder)
        let query = EmojiVectors.normalised(embedder.vector(for: "hilarious")!)!
        // "hilarious" is a keyword of the laughing faces, so these stay lexical hits; a word with
        // no entry at all has only its meaning to go on.
        #expect(search.search("lol", limit: 40).contains("😂"))
        let blended = search.search("hilarious", queryVector: query, vectors: table, limit: 40)
        #expect(blended.contains("😂"))
        let sleepy = EmojiVectors.normalised(embedder.vector(for: "yawn bed")!)!
        #expect(search.search("snoozing", limit: 40).isEmpty)
        let byMeaning = search.search("snoozing", queryVector: sleepy, vectors: table, limit: 40)
        #expect(byMeaning.contains("😴"))
    }

    @Test("Without a query vector or vectors the result is the lexical one")
    func lexicalFallback() {
        let table = vectors(for: FakeEmbedder())
        let plain = search.search("fire", limit: 10)
        #expect(search.search("fire", queryVector: nil, vectors: table, limit: 10) == plain)
        #expect(search.search("fire", queryVector: [1, 0, 0, 0], vectors: nil, limit: 10) == plain)
    }

    @Test("A query vector of the wrong length is ignored")
    func wrongLength() {
        let table = vectors(for: FakeEmbedder())
        #expect(search.search("fire", queryVector: [1, 0], vectors: table, limit: 10) == search.search("fire", limit: 10))
    }

    // MARK: Cache

    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-emoji-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(EmojiVectorCache.fileName)
    }

    @Test("A cache written for a revision and data hash reads back, and no other")
    func cacheRoundTrip() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let table = EmojiVectors(dimension: 3, values: [1, 0, 0, 0, 1, 0])
        try EmojiVectorCache.write(table, to: url, revision: "r1", dataHash: "h1", entries: 5)
        let back = EmojiVectorCache.load(from: url, revision: "r1", dataHash: "h1", entries: 5)
        #expect(back?.values == table.values)
        #expect(back?.count == 2)
        #expect(EmojiVectorCache.load(from: url, revision: "r2", dataHash: "h1", entries: 5) == nil)
        #expect(EmojiVectorCache.load(from: url, revision: "r1", dataHash: "h2", entries: 5) == nil)
        #expect(EmojiVectorCache.load(from: url, revision: "r1", dataHash: "h1", entries: 6) == nil)
    }

    @Test("A truncated or foreign file reads as absent")
    func cacheRejectsDamage() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let table = EmojiVectors(dimension: 3, values: [1, 0, 0, 0, 1, 0])
        try EmojiVectorCache.write(table, to: url, revision: "r1", dataHash: "h1", entries: 5)
        let whole = try Data(contentsOf: url)
        try whole.dropLast(3).write(to: url)
        #expect(EmojiVectorCache.load(from: url, revision: "r1", dataHash: "h1", entries: 5) == nil)
        try Data("not a cache at all, just text".utf8).write(to: url)
        #expect(EmojiVectorCache.load(from: url, revision: "r1", dataHash: "h1", entries: 5) == nil)
    }

    @Test("A store builds once, writes the cache, and a second store reads it without embedding")
    func storeBuildsAndReloads() {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = EmojiVectorStore(search: search, cacheURL: url)
        #expect(first.state == .idle)
        #expect(first.prepare(with: FakeEmbedder()) == .ready)
        #expect(first.vectors?.count == search.entries.count)

        // An embedder that must not be asked for an emoji's vector: it is only asked for a query.
        struct Refusing: EmojiEmbedder {
            let revision = "fake-1"
            let dimension = 4
            func vector(for text: String) -> [Float]? {
                Issue.record("embedded \(text)")
                return nil
            }
        }
        let second = EmojiVectorStore(search: search, cacheURL: url)
        #expect(second.prepare(with: Refusing()) == .ready)
        #expect(second.vectors?.values == first.vectors?.values)
    }

    @Test("Another embedder revision rebuilds")
    func revisionChangeRebuilds() {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = EmojiVectorStore(search: search, cacheURL: url)
        first.prepare(with: FakeEmbedder(revision: "fake-1"))
        let second = EmojiVectorStore(search: search, cacheURL: url)
        second.prepare(with: FakeEmbedder(revision: "fake-2"))
        #expect(EmojiVectorCache.load(from: url, revision: "fake-2", dataHash: search.dataHash, entries: search.entries.count) != nil)
        #expect(EmojiVectorCache.load(from: url, revision: "fake-1", dataHash: search.dataHash, entries: search.entries.count) == nil)
    }

    @Test("A build stopped partway resumes from its checkpoint")
    func resumes() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let embedder = FakeEmbedder()
        let full = vectors(for: embedder)
        // A checkpoint of the first 480 rows, as a killed process would leave.
        let cut = EmojiVectors(dimension: full.dimension, values: Array(full.values.prefix(480 * full.dimension)))
        try EmojiVectorCache.write(cut, to: url, revision: embedder.revision, dataHash: search.dataHash, entries: search.entries.count)
        final class Counter: @unchecked Sendable {
            var count = 0
        }
        struct Counting: EmojiEmbedder {
            let counter: Counter
            let inner = FakeEmbedder()
            var revision: String { inner.revision }
            var dimension: Int { inner.dimension }
            func vector(for text: String) -> [Float]? {
                counter.count += 1
                return inner.vector(for: text)
            }
        }
        let counter = Counter()
        let store = EmojiVectorStore(search: search, cacheURL: url)
        #expect(store.prepare(with: Counting(counter: counter)) == .ready)
        #expect(counter.count == search.entries.count - 480)
        #expect(store.vectors?.values == full.values)
    }

    @Test("Too little memory leaves the store unavailable and search lexical")
    func lowMemory() {
        let store = EmojiVectorStore(search: search, cacheURL: nil)
        #expect(store.prepare(with: FakeEmbedder(), isMemoryOK: { false }) == .unavailable)
        #expect(store.vectors == nil)
    }
}
