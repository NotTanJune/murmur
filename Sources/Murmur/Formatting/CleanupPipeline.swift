import Foundation

/// Cleans a long dictation in pieces while the key is still held.
///
/// The cleanup pass costs time in proportion to the text (S1-mini: roughly a second per
/// hundred words on an M2), and it used to start only at release, so a two-minute ramble
/// waited several seconds. An incremental engine reports a `stable` prefix of the transcript
/// as each window lands; this takes whole sentences from it and cleans them while the user is
/// still talking, so release cleans only the last few sentences.
///
/// Pieces are cut at sentence ends and never shorter than `minimumChunkWords`, so S1-mini
/// always sees complete sentences with some context. Each piece goes through the same
/// formatter as a whole transcript would, including its plausibility guard, so a rejected
/// piece falls back to the rule pass alone rather than taking the whole dictation with it.
///
/// `finish` checks that the final transcript still begins with the words handed out, word
/// for word. If the engine revised them, every piece is discarded and the whole transcript
/// is cleaned in one pass, as before: slower, never wrong.
@MainActor
final class CleanupPipeline {
    /// Fewer words than this wait for the next window. S1-mini's per-request overhead is
    /// constant, so tiny pieces would cost more than they save.
    static let minimumChunkWords = 12

    private let formatter: any TextFormatter
    /// Words of every piece handed to the formatter so far, exactly as the engine wrote them.
    private var consumed: [String] = []
    private var pieces: [Task<String, Never>] = []

    /// How many pieces were cleaned during the hold. For the log.
    private(set) var chunkCount = 0

    init(formatter: any TextFormatter) {
        self.formatter = formatter
    }

    /// Offers the engine's current stable prefix. Starts cleanup for any new whole sentences.
    func accept(stable: String) {
        let words = Self.words(stable)
        guard words.count > consumed.count, Array(words.prefix(consumed.count)) == consumed else {
            // Shorter than before, or revised: leave it; `finish` resolves the mismatch.
            return
        }
        let fresh = words[consumed.count...]
        guard let cut = fresh.lastIndex(where: Self.endsSentence) else { return }
        let chunk = Array(fresh[...cut])
        guard chunk.count >= Self.minimumChunkWords else { return }
        consumed.append(contentsOf: chunk)
        chunkCount += 1
        let text = chunk.joined(separator: " ")
        let formatter = self.formatter
        pieces.append(Task { await formatter.format(text) })
    }

    /// Cleans what the hold left over and joins it onto the pieces cleaned while held.
    /// `whole` cleans the full transcript in one pass; it runs when nothing was pipelined or
    /// the transcript no longer starts with the pipelined words.
    func finish(transcript: String, whole: () async -> String) async -> String {
        guard !pieces.isEmpty else { return await whole() }
        let words = Self.words(transcript)
        guard words.count >= consumed.count, Array(words.prefix(consumed.count)) == consumed else {
            Log.speech.notice("cleanup pipeline: final transcript differs from the text cleaned while held; cleaning the whole transcript")
            for piece in pieces { piece.cancel() }
            pieces.removeAll()
            return await whole()
        }
        let rest = words.dropFirst(consumed.count).joined(separator: " ")
        var parts: [String] = []
        for piece in pieces { parts.append(await piece.value) }
        if !rest.isEmpty { parts.append(await formatter.format(rest)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    func cancel() {
        for piece in pieces { piece.cancel() }
        pieces.removeAll()
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// A word that closes a sentence, allowing a trailing quote or bracket.
    static func endsSentence(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]"))
        guard let last = trimmed.last else { return false }
        return last == "." || last == "!" || last == "?"
    }
}
