import Foundation

/// The keyboard's English word model: a sorted word list with unigram frequencies and word-pair
/// probabilities, read in place from a memory-mapped `.mtm` file (format in `MTMFormat.md`).
///
/// Nothing is copied out of the file. The model holds the mapped `Data` and a few offsets, and
/// every query reads little-endian values straight from the mapped pages with unaligned loads.
/// Mapped pages that are only read count almost nothing against a keyboard extension's memory
/// limit, which is the whole reason for the format. Ids are indices in sorted-word order, so a
/// prefix is always one contiguous id range.
///
/// Immutable after `init`, so it is safe to share between threads; `bundled()` hands out one
/// shared instance.
public final class TypingModel: Sendable {
    /// Why a model file was refused.
    public enum LoadError: Error, Equatable {
        /// The module's bundle has no `en.mtm`.
        case missingResource
        /// The file is shorter than its own header or sections say.
        case truncated
        /// The file does not start with `MTM1`.
        case badMagic
        /// A version this reader does not know.
        case unsupportedVersion(UInt32)
        /// The sections do not add up to the file's length.
        case sizeMismatch
    }

    /// The number of words.
    public let wordCount: Int
    /// The number of stored word pairs.
    public let pairCount: Int

    private let data: Data
    private let unigramOffset: Int
    private let flagsOffset: Int
    private let firstLetterOffset: Int
    private let bucketOffset: Int
    private let endIdsOffset: Int
    private let pairIndexOffset: Int
    private let pairsOffset: Int
    private let blobOffset: Int

    /// The log10 probability a unigram or pair byte of 255 stands for, the floor of both scales.
    private static let floorLog10: Float = -255 / 25

    /// Maps the model at `url`. The file is checked against the layout in `MTMFormat.md`: its
    /// length must equal the sum of the sections.
    public init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let size = data.count
        guard size >= 16 else { throw LoadError.truncated }

        // All the bookkeeping reads happen in one closure over the mapped bytes, and none of its
        // results is a copy of a section: only counts and offsets leave it.
        let layout: (words: Int, pairs: Int, offsets: [Int]) = try data.withUnsafeBytes { raw in
            // "MTM1" read as a little-endian u32.
            guard Self.u32(raw, 0) == 0x314D_544D else { throw LoadError.badMagic }
            let version = Self.u32(raw, 4)
            guard version == 1 else { throw LoadError.unsupportedVersion(version) }
            let words = Int(Self.u32(raw, 8))
            let pairs = Int(Self.u32(raw, 12))

            func align4(_ value: Int) -> Int { (value + 3) & ~3 }
            let offsetsAt = 16
            let unigramAt = offsetsAt + 4 * (words + 1)
            let flagsAt = unigramAt + words
            let firstLetterAt = align4(flagsAt + words)
            let bucketAt = firstLetterAt + 4 * 27
            let endIdsAt = bucketAt + 4 * 677
            guard endIdsAt <= size else { throw LoadError.truncated }
            let endCount = Int(Self.u32(raw, bucketAt + 4 * 676))
            let pairIndexAt = align4(endIdsAt + 4 * endCount)
            let pairsAt = pairIndexAt + 4 * (words + 1)
            let blobAt = pairsAt + 5 * pairs
            guard blobAt <= size else { throw LoadError.truncated }
            let blobLength = Int(Self.u32(raw, offsetsAt + 4 * words))
            guard blobAt + blobLength == size else { throw LoadError.sizeMismatch }
            return (
                words, pairs,
                [unigramAt, flagsAt, firstLetterAt, bucketAt, endIdsAt, pairIndexAt, pairsAt, blobAt]
            )
        }

        self.data = data
        wordCount = layout.words
        pairCount = layout.pairs
        unigramOffset = layout.offsets[0]
        flagsOffset = layout.offsets[1]
        firstLetterOffset = layout.offsets[2]
        bucketOffset = layout.offsets[3]
        endIdsOffset = layout.offsets[4]
        pairIndexOffset = layout.offsets[5]
        pairsOffset = layout.offsets[6]
        blobOffset = layout.offsets[7]
    }

    /// The model bundled with this module, mapped once and shared by every caller, so the
    /// keyboard and the tests never map it twice.
    public static func bundled() throws -> TypingModel {
        try shared.get()
    }

    private static let shared = Result<TypingModel, any Error> {
        guard let url = TypingResources.modelURL else { throw LoadError.missingResource }
        return try TypingModel(url: url)
    }

    // MARK: - Words

    /// The id of exactly this word, or nil. The model stores lowercase words and straight
    /// apostrophes; callers fold case and apostrophes first.
    public func id(of word: String) -> Int? {
        let target = Array(word.utf8)
        return data.withUnsafeBytes { raw -> Int? in
            let index = lowerBound(raw, target)
            guard index < wordCount, compare(raw, index, target) == 0 else { return nil }
            return index
        }
    }

    /// The word with this id; empty for an id outside the model.
    public func word(_ id: Int) -> String {
        guard id >= 0, id < wordCount else { return "" }
        return data.withUnsafeBytes { raw in
            let (start, end) = wordBounds(raw, id)
            return String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<end]), as: UTF8.self)
        }
    }

    /// log10 of the word's probability among all words, from -10.2 (rarest representable) up to
    /// about -1.7 for "the". An id outside the model reads as the floor.
    public func unigram(_ id: Int) -> Float {
        guard id >= 0, id < wordCount else { return Self.floorLog10 }
        let byte = data.withUnsafeBytes { $0.load(fromByteOffset: unigramOffset + id, as: UInt8.self) }
        return -Float(byte) / 25
    }

    /// Whether the word is a contraction (`don't`).
    public func isContraction(_ id: Int) -> Bool {
        guard id >= 0, id < wordCount else { return false }
        let flags = data.withUnsafeBytes { $0.load(fromByteOffset: flagsOffset + id, as: UInt8.self) }
        return flags & 0b10 != 0
    }

    // MARK: - Prefixes

    /// Every id whose word starts with `prefix`, found by two binary searches. The range is the
    /// node of an implicit trie: `range(ofPrefix: "th")` contains `range(ofPrefix: "the")`. An
    /// empty prefix is every word, and a prefix nothing starts with is an empty range.
    public func range(ofPrefix prefix: String) -> Range<Int> {
        let target = Array(prefix.utf8)
        guard !target.isEmpty else { return 0..<wordCount }
        return data.withUnsafeBytes { raw in
            let lower = lowerBound(raw, target)
            // Words starting with the prefix sort directly after the prefix itself, so the upper
            // end is the first word that is neither smaller than the prefix nor starts with it.
            var low = lower
            var high = wordCount
            while low < high {
                let mid = (low + high) / 2
                if hasPrefix(raw, mid, target) { low = mid + 1 } else { high = mid }
            }
            return lower..<low
        }
    }

    /// The words of `range` whose byte at position `depth` is `byte`, where `range` is the id range
    /// of a prefix that is `depth` bytes long (`range(ofPrefix:)` of it, or an earlier `narrow`).
    /// That is the child of a trie node: `narrow(range(ofPrefix: "th"), depth: 2, byte: 0x65)` is
    /// `range(ofPrefix: "the")`. It is two binary searches inside `range` over single bytes, with no
    /// string built and nothing allocated, so a beam search can ask for thousands of children.
    /// The word equal to the prefix itself (shorter than `depth + 1` bytes) is in no child.
    public func narrow(_ range: Range<Int>, depth: Int, byte: UInt8) -> Range<Int> {
        guard !range.isEmpty, depth >= 0 else { return range.lowerBound..<range.lowerBound }
        let wanted = Int(byte)
        return data.withUnsafeBytes { raw in
            // `byteAt` is -1 for the prefix word itself, which sorts first in the range, so both
            // predicates below are false for it and then flip once, as a binary search needs.
            func byteAt(_ id: Int) -> Int {
                let (start, end) = wordBounds(raw, id)
                return start + depth < end ? Int(raw[start + depth]) : -1
            }
            func firstID(where predicate: (Int) -> Bool) -> Int {
                var low = range.lowerBound
                var high = range.upperBound
                while low < high {
                    let mid = (low + high) / 2
                    if predicate(byteAt(mid)) { high = mid } else { low = mid + 1 }
                }
                return low
            }
            let lower = firstID { $0 >= wanted }
            let upper = firstID { $0 > wanted }
            return lower..<upper
        }
    }

    /// The `limit` likeliest words starting with `prefix` (the prefix itself included when it is
    /// a word), most frequent first, ties broken by id.
    public func completions(prefix: String, limit: Int) -> [Int] {
        let range = range(ofPrefix: prefix)
        guard limit > 0, !range.isEmpty else { return [] }
        return data.withUnsafeBytes { raw in
            var best: [(id: Int, q: UInt8)] = []
            best.reserveCapacity(limit + 1)
            for id in range {
                let q = raw.load(fromByteOffset: unigramOffset + id, as: UInt8.self)
                // A smaller byte is a likelier word. Ids ascend, so an equal byte never beats
                // an earlier one and the tie-break needs no comparison.
                if best.count == limit, q >= best[limit - 1].q { continue }
                var slot = best.count
                while slot > 0, best[slot - 1].q > q { slot -= 1 }
                best.insert((id, q), at: slot)
                if best.count > limit { best.removeLast() }
            }
            return best.map(\.id)
        }
    }

    // MARK: - Pairs

    /// The words most likely to follow `id`, likeliest first (ties by id): the top `limit` of the
    /// word's stored pairs.
    public func next(after id: Int, limit: Int) -> [Int] {
        guard limit > 0, let range = pairRange(of: id) else { return [] }
        return data.withUnsafeBytes { raw in
            var best: [(id: Int, q: UInt8)] = []
            best.reserveCapacity(limit + 1)
            for index in range {
                let at = pairsOffset + 5 * index
                let q = raw.load(fromByteOffset: at + 4, as: UInt8.self)
                if best.count == limit, q >= best[limit - 1].q { continue }
                var slot = best.count
                while slot > 0, best[slot - 1].q > q { slot -= 1 }
                best.insert((Int(Self.u32(raw, at)), q), at: slot)
                if best.count > limit { best.removeLast() }
            }
            return best.map(\.id)
        }
    }

    /// Every stored successor of `id` with its log10 P(successor | id), in id order. For a few
    /// thousand pairs at most; the engine ranks them against the typed prefix.
    public func successors(of id: Int) -> [(id: Int, logP: Float)] {
        guard let range = pairRange(of: id) else { return [] }
        return data.withUnsafeBytes { raw in
            range.map { index in
                let at = pairsOffset + 5 * index
                return (Int(Self.u32(raw, at)), -Float(raw.load(fromByteOffset: at + 4, as: UInt8.self)) / 25)
            }
        }
    }

    /// log10 P(b | a), or nil when the pair is not stored. A binary search over `a`'s pairs,
    /// which are sorted by second id.
    public func pairLogP(_ a: Int, _ b: Int) -> Float? {
        guard let range = pairRange(of: a) else { return nil }
        return data.withUnsafeBytes { raw in
            var low = range.lowerBound
            var high = range.upperBound
            while low < high {
                let mid = (low + high) / 2
                let at = pairsOffset + 5 * mid
                let second = Int(Self.u32(raw, at))
                if second == b {
                    return -Float(raw.load(fromByteOffset: at + 4, as: UInt8.self)) / 25
                }
                if second < b { low = mid + 1 } else { high = mid }
            }
            return nil
        }
    }

    // MARK: - Swipe

    /// The ids of every word that starts with `first` and ends with `last` (letters a to z, case
    /// ignored), ascending. The swipe decoder uses it to cut the vocabulary to a few hundred
    /// candidates from the path's two ends alone. Empty for any other character.
    public func ids(first: Character, last: Character) -> some Collection<Int> {
        guard let f = Self.letterIndex(first), let l = Self.letterIndex(last) else {
            return MappedIDs(model: self, start: 0, count: 0)
        }
        let bucket = f * 26 + l
        let (start, end) = data.withUnsafeBytes { raw in
            (Int(Self.u32(raw, bucketOffset + 4 * bucket)), Int(Self.u32(raw, bucketOffset + 4 * (bucket + 1))))
        }
        return MappedIDs(model: self, start: start, count: end - start)
    }

    /// The words' ids as a collection over the mapped `endIds` section; nothing is copied.
    private struct MappedIDs: RandomAccessCollection, Sendable {
        let model: TypingModel
        let start: Int
        let count: Int

        var startIndex: Int { 0 }
        var endIndex: Int { count }

        subscript(position: Int) -> Int {
            precondition(position >= 0 && position < count, "index out of range")
            return model.data.withUnsafeBytes {
                Int(TypingModel.u32($0, model.endIdsOffset + 4 * (start + position)))
            }
        }
    }

    // MARK: - Internals

    /// A little-endian `u32` at a byte offset of the mapped file, with no alignment assumed.
    private static func u32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    private static func letterIndex(_ character: Character) -> Int? {
        guard let scalar = character.lowercased().unicodeScalars.first,
            character.lowercased().unicodeScalars.count == 1,
            scalar.value >= 97, scalar.value <= 122
        else { return nil }
        return Int(scalar.value) - 97
    }

    /// The range of `pairs` records owned by first word `id`, or nil for an id outside the model.
    private func pairRange(of id: Int) -> Range<Int>? {
        guard id >= 0, id < wordCount else { return nil }
        return data.withUnsafeBytes { raw in
            Int(Self.u32(raw, pairIndexOffset + 4 * id))..<Int(Self.u32(raw, pairIndexOffset + 4 * (id + 1)))
        }
    }

    /// The byte range of word `id` in the mapped file.
    private func wordBounds(_ raw: UnsafeRawBufferPointer, _ id: Int) -> (Int, Int) {
        // `offsets` starts right after the 16-byte header.
        (
            blobOffset + Int(Self.u32(raw, 16 + 4 * id)),
            blobOffset + Int(Self.u32(raw, 16 + 4 * (id + 1)))
        )
    }

    /// Orders word `id` against `target` by UTF-8 bytes: -1, 0 or 1 for smaller, equal, larger.
    private func compare(_ raw: UnsafeRawBufferPointer, _ id: Int, _ target: [UInt8]) -> Int {
        let (start, end) = wordBounds(raw, id)
        let length = end - start
        for position in 0..<min(length, target.count) {
            let byte = raw[start + position]
            if byte != target[position] { return byte < target[position] ? -1 : 1 }
        }
        return length == target.count ? 0 : (length < target.count ? -1 : 1)
    }

    /// Whether word `id` starts with the `prefix` bytes.
    private func hasPrefix(_ raw: UnsafeRawBufferPointer, _ id: Int, _ prefix: [UInt8]) -> Bool {
        let (start, end) = wordBounds(raw, id)
        guard end - start >= prefix.count else { return false }
        for position in 0..<prefix.count where raw[start + position] != prefix[position] {
            return false
        }
        return true
    }

    /// The first id whose word is not smaller than `target`, or `wordCount`.
    private func lowerBound(_ raw: UnsafeRawBufferPointer, _ target: [UInt8]) -> Int {
        var low = 0
        var high = wordCount
        while low < high {
            let mid = (low + high) / 2
            if compare(raw, mid, target) < 0 { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
