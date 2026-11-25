import Foundation

/// What the language model expects next at one word boundary: a probability for every word of
/// the keyboard's list that the model can write as one token.
///
/// It is computed once, when the text reaches the start of a word, and answers both questions
/// the strip asks until the next word starts: the likeliest next words (`best`), and, while the
/// word is typed, the likeliest words with the typed prefix (`candidates(in:)`). Word ids are
/// `TypingModel`'s, which are in sorted-word order, so a prefix is one contiguous id range and
/// the second question is a binary search and a short scan. Nothing runs per keystroke.
public struct WordPrediction: Sendable {
    public typealias Entry = (id: Int, probability: Float)

    /// How many of the likeliest words `best` keeps: enough that three survive the strip's rules.
    static let bestCount = 48

    /// The text the prediction was made for: everything before the cursor up to the start of the
    /// word being typed (`SuggestionEngine.boundary(before:)`). The engine uses a prediction only
    /// for a text with exactly this boundary.
    public let boundary: String
    /// The words with a probability, ascending by id, and their probabilities.
    private let ids: [Int32]
    private let probabilities: [Float]
    /// The likeliest words, most probable first.
    public let best: [Entry]

    /// `ids` must be ascending with no repeats, and `probabilities` the same length.
    init(boundary: String, ids: [Int32], probabilities: [Float]) {
        precondition(ids.count == probabilities.count)
        self.boundary = boundary
        self.ids = ids
        self.probabilities = probabilities
        // One pass with a small sorted buffer; ties go to the lower id so the order never
        // depends on anything but the numbers.
        var top: [Entry] = []
        top.reserveCapacity(Self.bestCount + 1)
        for index in ids.indices {
            let probability = probabilities[index]
            guard probability > 0 else { continue }
            if top.count == Self.bestCount, probability <= top[top.count - 1].probability { continue }
            let place = top.firstIndex { $0.probability < probability } ?? top.count
            top.insert((Int(ids[index]), probability), at: place)
            if top.count > Self.bestCount { top.removeLast() }
        }
        best = top
    }

    /// A prediction from loose scores, for tests and tools.
    init(boundary: String, scores: [Int: Float]) {
        let sorted = scores.sorted { $0.key < $1.key }
        self.init(boundary: boundary, ids: sorted.map { Int32($0.key) }, probabilities: sorted.map(\.value))
    }

    /// The words in an id range (a prefix's, from `TypingModel.range(ofPrefix:)`) that the model
    /// gave a probability, in id order.
    func candidates(in range: Range<Int>) -> [Entry] {
        var low = 0
        var high = ids.count
        while low < high {
            let middle = (low + high) / 2
            if Int(ids[middle]) < range.lowerBound { low = middle + 1 } else { high = middle }
        }
        var entries: [Entry] = []
        while low < ids.count, Int(ids[low]) < range.upperBound {
            if probabilities[low] > 0 { entries.append((Int(ids[low]), probabilities[low])) }
            low += 1
        }
        return entries
    }
}
