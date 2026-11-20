import Foundation
import Testing
@testable import Murmur

/// Marks each request so a test can tell which text was cleaned when, and how many times.
private actor RecordingFormatter: TextFormatter {
    var requests: [String] = []
    func format(_ raw: String) async -> String {
        requests.append(raw)
        return "<" + raw + ">"
    }
}

@MainActor
struct CleanupPipelineTests {
    @Test("Whole sentences are cleaned as the stable prefix grows; the tail waits for release")
    func piecewise() async {
        let formatter = RecordingFormatter()
        let pipeline = CleanupPipeline(formatter: formatter)
        let first = "We should move the launch to Monday because the team needs two more days for the page."
        let second = "Also ping Marcus about pricing, he said he would have numbers by Wednesday."
        let tail = "Let me know what you think"

        pipeline.accept(stable: first + " Also ping")
        #expect(pipeline.chunkCount == 1)
        pipeline.accept(stable: first + " " + second + " " + tail)
        #expect(pipeline.chunkCount == 2)

        let output = await pipeline.finish(transcript: first + " " + second + " " + tail + " tomorrow.") {
            Issue.record("the whole-text pass must not run when the pieces still match")
            return ""
        }
        #expect(output == "<\(first)> <\(second)> <\(tail) tomorrow.>")
        #expect(await formatter.requests == [first, second, tail + " tomorrow."])
    }

    @Test("Short fragments wait for the next window instead of becoming tiny requests")
    func minimumSize() async {
        let formatter = RecordingFormatter()
        let pipeline = CleanupPipeline(formatter: formatter)
        pipeline.accept(stable: "Okay so.")
        pipeline.accept(stable: "Okay so. Let's go.")
        #expect(pipeline.chunkCount == 0)
        #expect(await formatter.requests.isEmpty)
    }

    @Test("A final transcript that no longer starts with the cleaned words falls back to one pass")
    func revisedTranscript() async {
        let formatter = RecordingFormatter()
        let pipeline = CleanupPipeline(formatter: formatter)
        let sentence = "The quick brown fox jumps over the lazy dog near the river bank today."
        pipeline.accept(stable: sentence + " And")
        #expect(pipeline.chunkCount == 1)
        let final = "A quick brown fox jumps over the lazy dog near the river bank today. And more."
        var wholeRan = false
        let output = await pipeline.finish(transcript: final) {
            wholeRan = true
            return "WHOLE"
        }
        #expect(wholeRan)
        #expect(output == "WHOLE")
    }

    @Test("Nothing pipelined means the ordinary whole-text pass")
    func nothingPipelined() async {
        let pipeline = CleanupPipeline(formatter: RecordingFormatter())
        let output = await pipeline.finish(transcript: "Short.") { "WHOLE" }
        #expect(output == "WHOLE")
    }

    @Test("Sentence ends are recognized through closing quotes and brackets")
    func sentenceEnds() {
        #expect(CleanupPipeline.endsSentence("done."))
        #expect(CleanupPipeline.endsSentence("really?\""))
        #expect(CleanupPipeline.endsSentence("(sure!)"))
        #expect(!CleanupPipeline.endsSentence("and"))
        #expect(!CleanupPipeline.endsSentence("3.5"))
    }
}

extension CleanupPipelineTests {
    @Test("A period Bark wrote at a pause, with the next word lowercase, does not end a piece")
    func pausePeriodIsNotASentenceEnd() async {
        // Thirteen words up to the pause period, so only the rule keeps this from being cut.
        let pause = "We should move the launch to Monday because the team said they had. two more days"
        let formatter = RecordingFormatter()
        let pipeline = CleanupPipeline(formatter: formatter)
        pipeline.accept(stable: pause)
        #expect(pipeline.chunkCount == 0)
        #expect(await formatter.requests.isEmpty)

        // The real sentence end after it cuts, and the pause period travels inside the piece.
        let rest = "for the page. Also ping Marcus"
        pipeline.accept(stable: pause + " " + rest)
        #expect(pipeline.chunkCount == 1)
        let output = await pipeline.finish(transcript: pause + " " + rest) {
            Issue.record("the whole-text pass must not run when the pieces still match")
            return ""
        }
        #expect(output == "<\(pause) for the page.> <Also ping Marcus>")
        #expect(await formatter.requests == [pause + " for the page.", "Also ping Marcus"])
    }

    @Test("A period on the last stable word waits for the next window to show what follows it")
    func periodAtTheEndOfStableWaits() async {
        // 2026-11-10: the stable text ended "what I have to rework to." and the next window
        // began "do is basically"; cutting there typed "to. Do".
        let stable = "So that is one of the things that I think I have to rework to."
        let formatter = RecordingFormatter()
        let pipeline = CleanupPipeline(formatter: formatter)
        pipeline.accept(stable: stable)
        #expect(pipeline.chunkCount == 0)

        let more = stable + " do is basically show our working. Then"
        pipeline.accept(stable: more)
        #expect(pipeline.chunkCount == 1)
        _ = await pipeline.finish(transcript: more) { "" }
        #expect(await formatter.requests.first == stable + " do is basically show our working.")
    }
}
