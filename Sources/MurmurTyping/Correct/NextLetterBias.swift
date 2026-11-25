import Foundation

/// How likely each letter is to come next, from the word model: the numbers `HitTester` uses to
/// let a likelier letter claim a few points of its neighbour's touch area.
///
/// The estimate for a prefix is the share of probability, among the words that start with it,
/// held by the words that continue with each letter. A word's probability blends its frequency
/// with its probability after the previous word, the way the suggestion strip ranks words
/// (`SuggestionEngine.bigramWeight`), so after "thank" the letter "y" is far likelier than its
/// frequency alone says.
///
/// It runs on every keystroke, so the work is bounded:
/// - A prefix of up to two letters reads a table of 26 + 676 sums built once in `init` (one pass
///   over the unigram column, no words decoded), because those ranges hold thousands of words.
/// - A longer prefix scans its own id range, at most `scanBudget` ids: a range larger than that is
///   sampled at a fixed stride and scaled. In the bundled model the largest two-letter range
///   ("co") holds 3,101 words and the largest three-letter range 1,128, so the cap is the
///   guarantee, not the common case. Measured in a debug build, a call takes 15 to 450 µs.
/// - The previous word contributes its `successorBudget` likeliest successors, each looked up by
///   binary search.
///
/// A call therefore costs at most about `scanBudget + 26 · log(range) + successorBudget · log(pairs)`
/// reads of the mapped file and allocates one 26-entry array and one dictionary.
public final class NextLetterBias: Sendable {
    /// The most ids one call reads from a prefix's range.
    public static let scanBudget = 4096
    /// How many of the previous word's successors one call looks at.
    public static let successorBudget = 256
    /// The share of a word's weight that comes from the previous word, as in `SuggestionEngine`.
    public static let bigramWeight = 0.7
    /// The lowest log-odds returned, for a letter no word continues with.
    public static let floor = -6.0
    /// The highest log-odds returned.
    public static let ceiling = 6.0

    private let model: TypingModel
    /// Probability of a quantised unigram byte (`unigram` is `-q / 25` in log10).
    private let probability: [Double]
    /// The probability mass of the words that start with each letter.
    private let firstMass: [Double]
    /// The mass of the words that start with each pair of letters, `first * 26 + second`.
    private let pairMass: [Double]

    /// Builds the two small tables. One pass over the model's unigram column; do it once, off the
    /// typing path.
    public init(model: TypingModel) {
        self.model = model
        let table = (0...255).map { pow(10.0, -Double($0) / 25) }
        probability = table
        var first = [Double](repeating: 0, count: 26)
        var pairs = [Double](repeating: 0, count: 26 * 26)
        let all = 0..<model.wordCount
        for a in 0..<26 {
            let rangeA = model.narrow(all, depth: 0, byte: Self.byte(a))
            for b in 0..<26 {
                let rangeAB = model.narrow(rangeA, depth: 1, byte: Self.byte(b))
                var sum = 0.0
                for id in rangeAB { sum += table[Self.quantised(model.unigram(id))] }
                pairs[a * 26 + b] = sum
                first[a] += sum
            }
            // Words that are one letter long ("a") are in the range but in no child; they have no
            // next letter, so they are left out on purpose.
        }
        firstMass = first
        pairMass = pairs
    }

    /// The log-odds that each letter, "a" to "z", is typed next after `prefix` (the letters of the
    /// current word so far, any case) when the word before it is `previous`.
    ///
    /// All 26 letters are present when anything can follow, because `HitTester` reads an absent
    /// letter as 0, which would outrank a rare letter's negative number. Empty when no word starts
    /// with `prefix`, which means no bias.
    public func logOdds(prefix: String, previous: Int?) -> [String: Double] {
        let folded = UserLexicon.fold(prefix)
        let depth = folded.utf8.count
        let parent = model.range(ofPrefix: folded)
        guard !parent.isEmpty else { return [:] }

        var unigram = [Double](repeating: 0, count: 26)
        let bytes = Array(folded.utf8)
        if depth == 0 {
            unigram = firstMass
        } else if depth == 1, let letter = Self.index(bytes[0]) {
            unigram = Array(pairMass[(letter * 26)..<(letter * 26 + 26)])
        } else {
            let stride = max(1, (parent.count + Self.scanBudget - 1) / Self.scanBudget)
            for letter in 0..<26 {
                let child = model.narrow(parent, depth: depth, byte: Self.byte(letter))
                var sum = 0.0
                var id = child.lowerBound
                while id < child.upperBound {
                    sum += probability[Self.quantised(model.unigram(id))]
                    id += stride
                }
                unigram[letter] = sum * Double(stride)
            }
        }

        var bigram = [Double](repeating: 0, count: 26)
        if let previous {
            for id in model.next(after: previous, limit: Self.successorBudget) where parent.contains(id) {
                guard let logP = model.pairLogP(previous, id) else { continue }
                let word = Array(model.word(id).utf8)
                guard word.count > depth, let letter = Self.index(word[depth]) else { continue }
                bigram[letter] += pow(10, Double(logP))
            }
        }

        let mass = (0..<26).map { (1 - Self.bigramWeight) * unigram[$0] + Self.bigramWeight * bigram[$0] }
        let total = mass.reduce(0, +)
        guard total > 0 else { return [:] }
        var result: [String: Double] = [:]
        for letter in 0..<26 {
            let share = mass[letter] / total
            let odds = share <= 0 ? Self.floor : log(share / max(1 - share, 1e-12))
            result[String(UnicodeScalar(Self.byte(letter)))] = min(max(odds, Self.floor), Self.ceiling)
        }
        return result
    }

    // MARK: - Helpers

    private static func byte(_ letter: Int) -> UInt8 { 97 + UInt8(letter) }

    private static func index(_ byte: UInt8) -> Int? {
        byte >= 97 && byte < 123 ? Int(byte - 97) : nil
    }

    private static func quantised(_ log10: Float) -> Int {
        min(max(Int((-log10 * 25).rounded()), 0), 255)
    }
}
