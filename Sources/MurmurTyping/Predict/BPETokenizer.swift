import Foundation

/// GPT-2's byte-level byte-pair encoding, which the keyboard's language model reads its text
/// through. Murmur's own code, written from the published description of the scheme and checked
/// against vectors from the reference tokenizer (`bpe-vectors.json`).
///
/// The scheme has three steps. The text is cut into pieces (a word with the space before it, a
/// run of digits, a run of marks, a contraction's ending, a run of whitespace). Each piece
/// becomes its UTF-8 bytes, every byte a token of its own. Then, inside a piece, the pair of
/// neighbouring tokens that the merge list names earliest is joined into one token, again and
/// again, until no neighbouring pair is on the list.
///
/// It loads from the model's own two files: `vocab.json` (token text to id, with each byte
/// written as one printable character) and `merges.txt` (one pair a line, earliest first). After
/// loading it works on ids alone: the merge table is keyed by a pair of ids, so encoding makes no
/// strings. Immutable, so it is safe to share between threads.
public struct BPETokenizer: Sendable {
    public enum LoadError: Error, Equatable {
        /// `vocab.json` is not an object of token text to id.
        case unreadableVocabulary
        /// The vocabulary has no token for this byte, so it is not a byte-level vocabulary.
        case missingByte(UInt8)
        /// `merges.txt` named no pair the vocabulary knows.
        case noMerges
    }

    /// Every token's text as the vocabulary writes it, by id: bytes as printable characters, a
    /// leading space as `Ġ`. Ids the vocabulary skips are empty.
    public let tokens: [String]
    /// The id of `<|endoftext|>`, which the model saw between documents. Nil when the
    /// vocabulary has none.
    public let endOfText: Int32?

    /// The character a leading space is written as in `tokens` (byte 32, moved to U+0120).
    public static let spaceMark: Character = "Ġ"

    private let byteTokens: [Int32]
    /// A pair of ids (left in the high half) to its place in the merge list and the id it becomes.
    private let merges: [UInt64: Merge]

    private struct Merge: Sendable {
        let rank: Int32
        let token: Int32
    }

    public init(vocabulary: URL, merges mergesURL: URL) throws {
        // `JSONSerialization` and not `JSONDecoder`: the decoder left about 6 MB more in the
        // process's footprint for a table this size (measured on a Mac, 2026-11-25).
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: vocabulary, options: .alwaysMapped))
        guard let object = parsed as? NSDictionary else { throw LoadError.unreadableVocabulary }
        var ids: [String: Int32] = [:]
        ids.reserveCapacity(object.count)
        for (text, id) in object {
            guard let text = text as? String, let id = (id as? NSNumber)?.int32Value else {
                throw LoadError.unreadableVocabulary
            }
            ids[text] = id
        }
        guard let last = ids.values.max(), last < 1_000_000 else { throw LoadError.unreadableVocabulary }
        var tokens = [String](repeating: "", count: Int(last) + 1)
        for (text, id) in ids where id >= 0 { tokens[Int(id)] = text }
        self.tokens = tokens
        endOfText = ids["<|endoftext|>"]

        byteTokens = try Self.byteCharacters.enumerated().map { byte, character in
            guard let id = ids[String(character)] else { throw LoadError.missingByte(UInt8(byte)) }
            return id
        }

        var table: [UInt64: Merge] = [:]
        table.reserveCapacity(ids.count)
        var rank: Int32 = 0
        // Line by line, and not one array of 50,000 lines: slower by a tenth of a second on a
        // Mac and 3 MB lighter. The load runs once, off the main thread; memory is the limit.
        try String(contentsOf: mergesURL, encoding: .utf8).enumerateLines { line, _ in
            // A token's text never holds a space (the space byte is written as `Ġ`), so the one
            // space on the line separates the pair.
            guard !line.hasPrefix("#version"), let gap = line.firstIndex(of: " ") else { return }
            let left = String(line[..<gap])
            let right = String(line[line.index(after: gap)...])
            defer { rank += 1 }
            guard let leftID = ids[left], let rightID = ids[right], let joined = ids[left + right] else { return }
            table[Self.key(leftID, rightID)] = Merge(rank: rank, token: joined)
        }
        guard !table.isEmpty else { throw LoadError.noMerges }
        merges = table
    }

    /// The token ids of `text`. No start or end token is added.
    public func encode(_ text: String) -> [Int32] {
        let scalars = Array(text.unicodeScalars)
        var ids: [Int32] = []
        var piece: [Int32] = []
        for range in Self.pieces(of: scalars) {
            piece.removeAll(keepingCapacity: true)
            for scalar in scalars[range] {
                guard let bytes = Unicode.UTF8.encode(scalar) else { continue }
                for byte in bytes { piece.append(byteTokens[Int(byte)]) }
            }
            merge(&piece)
            ids.append(contentsOf: piece)
        }
        return ids
    }

    /// Joins neighbouring pairs in merge-list order until none is left: the earliest-listed pair
    /// present is found, every occurrence of it is joined left to right, and the search starts
    /// over.
    private func merge(_ piece: inout [Int32]) {
        while piece.count > 1 {
            var best: (rank: Int32, left: Int32, right: Int32, token: Int32)?
            for index in 0..<(piece.count - 1) {
                guard let merge = merges[Self.key(piece[index], piece[index + 1])] else { continue }
                if best == nil || merge.rank < best!.rank {
                    best = (merge.rank, piece[index], piece[index + 1], merge.token)
                }
            }
            guard let best else { return }
            var joined: [Int32] = []
            joined.reserveCapacity(piece.count - 1)
            var index = 0
            while index < piece.count {
                if index + 1 < piece.count, piece[index] == best.left, piece[index + 1] == best.right {
                    joined.append(best.token)
                    index += 2
                } else {
                    joined.append(piece[index])
                    index += 1
                }
            }
            piece = joined
        }
    }

    private static func key(_ left: Int32, _ right: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: left)) << 32 | UInt64(UInt32(bitPattern: right))
    }

    // MARK: - Bytes

    /// The character each byte is written as in the vocabulary: itself where Latin-1 has a
    /// printable character for it, and otherwise the next unused code point from U+0100 up, in
    /// byte order. That puts the space at U+0120.
    private static let byteCharacters: [Character] = {
        var characters: [Character] = []
        var moved: UInt32 = 0
        for byte in UInt32(0)...255 {
            let printable = (33...126).contains(byte) || (161...172).contains(byte) || (174...255).contains(byte)
            let scalar = printable ? byte : 256 + moved
            if !printable { moved += 1 }
            characters.append(Character(Unicode.Scalar(scalar)!))
        }
        return characters
    }()

    // MARK: - Pieces

    private enum Class {
        case space, letter, number, other
    }

    private static func classify(_ scalar: Unicode.Scalar) -> Class {
        if scalar.properties.isWhitespace { return .space }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return .letter
        case .decimalNumber, .letterNumber, .otherNumber: return .number
        default: return .other
        }
    }

    /// The endings a contraction is cut off as, whatever follows them.
    private static let endings: [[Unicode.Scalar]] = [["s"], ["t"], ["r", "e"], ["v", "e"], ["m"], ["l", "l"], ["d"]]

    /// Cuts the text into the pieces merging happens within. At each position, in this order: a
    /// contraction ending (`'s 't 're 've 'm 'll 'd`); one optional space and then a run of
    /// letters, a run of digits, or a run of anything else that is not whitespace; a run of
    /// whitespace. A whitespace run that text follows gives up its last character, so a space
    /// stays with the word after it, the way the vocabulary's tokens are written.
    private static func pieces(of scalars: [Unicode.Scalar]) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        let count = scalars.count
        var index = 0
        while index < count {
            if scalars[index] == "'",
                let ending = endings.first(where: { scalars[(index + 1)...].starts(with: $0) })
            {
                pieces.append(index..<(index + 1 + ending.count))
                index += 1 + ending.count
                continue
            }
            var start = index
            if scalars[start] == " ", start + 1 < count, classify(scalars[start + 1]) != .space { start += 1 }
            let kind = classify(scalars[start])
            var end = start
            while end < count, classify(scalars[end]) == kind { end += 1 }
            if kind == .space, end < count, end - index >= 2 { end -= 1 }
            pieces.append(index..<end)
            index = end
        }
        return pieces
    }
}
