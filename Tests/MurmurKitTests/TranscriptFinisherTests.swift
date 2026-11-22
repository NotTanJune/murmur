import Foundation
import Testing
import MurmurDictionary
@testable import MurmurKit

/// Marks its output so a test can tell the formatter ran, and records what it was given.
private actor MarkingFormatter: TextFormatter {
    var requests: [String] = []
    func format(_ raw: String) async -> String {
        requests.append(raw)
        return "<" + raw + ">"
    }
}

@MainActor
struct TranscriptFinisherTests {
    private let cloudCode = DictionaryCorrector(entries: [
        DictionaryEntry.correction(hear: "cloud code", write: "Claude Code"),
    ])

    @Test("With cleanup off the raw text still gets the dictionary")
    func cleanupOffStillAppliesDictionary() async {
        let formatter = MarkingFormatter()
        let result = await TranscriptFinisher.finish(
            raw: "use cloud code", cleanupEnabled: false, formatter: formatter,
            pipeline: nil, corrector: cloudCode)
        #expect(result.text == "use Claude Code")
        #expect(result.applied.count == 1)
        #expect(await formatter.requests.isEmpty)
    }

    @Test("Rules run first, so the dictionary sees the cleaned text")
    func rulesThenDictionary() async {
        let corrector = DictionaryCorrector(entries: [
            DictionaryEntry.correction(hear: "NUS campus", write: "NUS Kent Ridge campus"),
        ])
        let result = await TranscriptFinisher.finish(
            raw: "um so the n u s campus", cleanupEnabled: true, formatter: RuleBasedFormatter(),
            pipeline: nil, corrector: corrector)
        #expect(result.text.contains("NUS"))
        // Only matches if the rule pass joined "n u s" before the dictionary ran.
        #expect(result.text.contains("NUS Kent Ridge campus"))
        #expect(result.applied.count == 1)
    }

    @Test("A pipeline with no pieces falls back to the formatter's whole-text output")
    func pipelineFallsBackToFormatter() async {
        let formatter = MarkingFormatter()
        let pipeline = CleanupPipeline(formatter: formatter)
        let result = await TranscriptFinisher.finish(
            raw: "short one", cleanupEnabled: true, formatter: formatter,
            pipeline: pipeline, corrector: DictionaryCorrector(entries: []))
        #expect(result.text == "<short one>")
        #expect(await formatter.requests == ["short one"])
    }
}
