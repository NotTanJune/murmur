import Foundation

#if canImport(NaturalLanguage)
import NaturalLanguage

/// Apple's on-device English sentence embedding as an `EmojiEmbedder`. Nothing is bundled: the
/// model is a system asset, absent on some devices, in which case `init` returns nil and search
/// stays lexical. `NLEmbedding` is not documented as thread-safe, so every call takes a lock.
public final class NLEmbeddingEmojiEmbedder: EmojiEmbedder, @unchecked Sendable {
    private let embedding: NLEmbedding
    private let lock = NSLock()
    public let revision: String
    public let dimension: Int

    public init?() {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        self.embedding = embedding
        dimension = embedding.dimension
        revision = "nl-sentence-en-\(NLEmbedding.currentSentenceEmbeddingRevision(for: .english))"
    }

    public func vector(for text: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return embedding.vector(for: text)?.map { Float($0) }
    }
}
#endif

/// The emoji vectors on disk. One file in the storage root, valid only for the embedder
/// revision and the emoji data it was built from; anything else reads as absent.
///
/// Layout, little endian: `MEV1`, dimension, rows, entries (each UInt32), the revision and the
/// data hash (each a UInt16 length and UTF-8 bytes), then `rows * dimension` Float32 values.
/// `rows` can be below `entries` for a build that was cut short; a later build resumes there.
public enum EmojiVectorCache {
    public static let fileName = "emoji-vectors.bin"
    private static let magic = Data("MEV1".utf8)

    public static func url(in root: URL) -> URL { root.appendingPathComponent(fileName) }

    public static func load(from url: URL, revision: String, dataHash: String, entries: Int) -> EmojiVectors? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 16,
              data.prefix(4) == magic else { return nil }
        var offset = 4
        func readInt() -> Int? {
            guard offset + 4 <= data.count else { return nil }
            let value = data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            offset += 4
            return Int(UInt32(littleEndian: value))
        }
        func readString() -> String? {
            guard offset + 2 <= data.count else { return nil }
            let length = Int(data.subdata(in: offset..<offset + 2).withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) })
            offset += 2
            guard offset + length <= data.count else { return nil }
            defer { offset += length }
            return String(data: data.subdata(in: offset..<offset + length), encoding: .utf8)
        }
        guard let dimension = readInt(), let rows = readInt(), let stored = readInt(),
              let storedRevision = readString(), let storedHash = readString(),
              storedRevision == revision, storedHash == dataHash, stored == entries,
              dimension > 0, rows <= entries, data.count - offset == rows * dimension * 4 else { return nil }
        var values = [Float](repeating: 0, count: rows * dimension)
        values.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[offset...]))
            }
        }
        return EmojiVectors(dimension: dimension, values: values)
    }

    public static func write(_ vectors: EmojiVectors, to url: URL, revision: String, dataHash: String, entries: Int) throws {
        var data = magic
        func append(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func append(_ text: String) {
            let bytes = Array(text.utf8)
            withUnsafeBytes(of: UInt16(bytes.count).littleEndian) { data.append(contentsOf: $0) }
            data.append(contentsOf: bytes)
        }
        append(vectors.dimension)
        append(vectors.count)
        append(entries)
        append(revision)
        append(dataHash)
        vectors.values.withUnsafeBytes { data.append(contentsOf: $0) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Builds and holds the emoji vectors for one `EmojiSearch` and one embedder. `prepare` loads the
/// cache or, failing that, embeds every emoji's text on the calling thread (call it from a
/// background task), checkpointing as it goes. Reads (`vectors`, `embed`) are safe from any
/// thread and never wait for a build: until the vectors are complete they are nil, and search
/// is lexical only.
public final class EmojiVectorStore: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case building(done: Int, of: Int)
        case ready
        /// No embedder, no memory, or a build that was cancelled: search stays lexical.
        case unavailable
    }

    private let search: EmojiSearch
    private let cacheURL: URL?
    private let lock = NSLock()
    private var embedder: (any EmojiEmbedder)?
    private var table: EmojiVectors?
    private var current = State.idle
    private var cancelled = false
    /// How many emoji are embedded between checkpoints of the cache file.
    private let checkpointEvery = 480

    public init(search: EmojiSearch = .standard, cacheURL: URL?) {
        self.search = search
        self.cacheURL = cacheURL
    }

    public var state: State { lock.withLock { current } }

    /// The complete table, or nil while it is not ready.
    public var vectors: EmojiVectors? { lock.withLock { table } }

    /// A unit-length vector for a query, or nil when there is no embedder or no vector for it.
    /// Calls the embedder, so keep it off the main thread.
    public func embed(_ query: String) -> [Float]? {
        guard let embedder = lock.withLock({ self.embedder }), let raw = embedder.vector(for: query),
              raw.count == embedder.dimension else { return nil }
        return EmojiVectors.normalised(raw)
    }

    /// Stops a build at its next checkpoint; the store then reads `unavailable`.
    public func cancel() { lock.withLock { cancelled = true } }

    /// Forgets the table and the embedder, to give their memory back. `prepare` can run again.
    public func release() {
        lock.withLock {
            table = nil
            embedder = nil
            current = .idle
        }
    }

    /// Loads or builds the vectors with `embedder`. Returns the final state. A second call while
    /// one is running, or after the store is ready, returns at once.
    @discardableResult
    public func prepare(with embedder: any EmojiEmbedder, isMemoryOK: () -> Bool = { true }) -> State {
        let proceed: Bool = lock.withLock {
            switch current {
            case .idle, .unavailable:
                current = .building(done: 0, of: search.entries.count)
                cancelled = false
                self.embedder = embedder
                return true
            case .building, .ready:
                return false
            }
        }
        guard proceed else { return state }

        let entries = search.entries.count
        let hash = search.dataHash
        var partial: EmojiVectors?
        if let url = cacheURL,
           let cached = EmojiVectorCache.load(from: url, revision: embedder.revision, dataHash: hash, entries: entries),
           cached.dimension == embedder.dimension {
            if cached.count == entries { return finish(cached) }
            partial = cached
        }

        guard isMemoryOK() else { return fail() }
        let dimension = embedder.dimension
        var values = partial?.values ?? []
        values.reserveCapacity(entries * dimension)
        var done = values.count / dimension
        while done < entries {
            if lock.withLock({ cancelled }) { return fail() }
            let row = EmojiVectors.normalised(embedder.vector(for: search.embeddingText(at: done)) ?? [])
            if let row, row.count == dimension {
                values.append(contentsOf: row)
            } else {
                values.append(contentsOf: [Float](repeating: 0, count: dimension))
            }
            done += 1
            if done % checkpointEvery == 0, done < entries {
                lock.withLock { current = .building(done: done, of: entries) }
                if let url = cacheURL {
                    try? EmojiVectorCache.write(
                        EmojiVectors(dimension: dimension, values: values), to: url,
                        revision: embedder.revision, dataHash: hash, entries: entries)
                }
            }
        }
        let table = EmojiVectors(dimension: dimension, values: values)
        if let url = cacheURL {
            try? EmojiVectorCache.write(table, to: url, revision: embedder.revision, dataHash: hash, entries: entries)
        }
        return finish(table)
    }

    private func finish(_ table: EmojiVectors) -> State {
        lock.withLock {
            self.table = table
            current = .ready
            return current
        }
    }

    private func fail() -> State {
        lock.withLock {
            embedder = nil
            current = .unavailable
            return current
        }
    }
}
