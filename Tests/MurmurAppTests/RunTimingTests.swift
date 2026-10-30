import Foundation
import Testing
@testable import Murmur

struct RunTimingTests {
    @Test("Old history still decodes and shows its original processing time")
    func legacyTiming() throws {
        let data = Data(#"{"date":0,"engine":"Apple (streaming)","audioSeconds":10,"processSeconds":0.2,"text":"Hello"}"#.utf8)
        let run = try JSONDecoder().decode(DictationRun.self, from: data)
        #expect(run.displayedLatency == 0.2)
        #expect(run.deliverySeconds == nil)
    }

    @Test("New history exposes delivery latency without losing recognizer timing")
    func deliveryTiming() throws {
        let data = Data(#"{"date":0,"engine":"Nemotron (streaming)","audioSeconds":10,"processSeconds":0.1,"deliverySeconds":0.15,"text":"Hello"}"#.utf8)
        let run = try JSONDecoder().decode(DictationRun.self, from: data)
        #expect(run.displayedLatency == 0.15)
        #expect(run.processSeconds == 0.1)
        let restored = try JSONDecoder().decode(DictationRun.self, from: JSONEncoder().encode(run))
        #expect(restored.deliverySeconds == 0.15)
    }
}

struct HistoryRetentionTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    private static func run(daysAgo: Double, saved: Bool = false) -> DictationRun {
        DictationRun(
            date: now.addingTimeInterval(-daysAgo * day),
            engine: "Bark 3.0 Clean (batch)",
            audioSeconds: 2,
            processSeconds: 0.1,
            text: "hello",
            isSaved: saved
        )
    }

    @Test("Unsaved runs expire after 30 days; saved runs never do")
    func retention() {
        let recent = Self.run(daysAgo: 29)
        let expired = Self.run(daysAgo: 31)
        let savedOld = Self.run(daysAgo: 400, saved: true)
        let kept = RunLog.retained([expired, recent, savedOld], now: Self.now)
        #expect(kept.map(\.id) == [recent.id, savedOld.id])
    }

    @Test("Lines written before saving existed decode as unsaved, and the flag round-trips")
    func savedFlagCoding() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = Data(#"{"date":"2026-10-01T10:00:00Z","engine":"Parakeet","audioSeconds":1,"processSeconds":0.2,"text":"hi"}"#.utf8)
        #expect(try decoder.decode(DictationRun.self, from: legacy).isSaved == false)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let saved = Self.run(daysAgo: 1, saved: true)
        let decoded = try decoder.decode(DictationRun.self, from: encoder.encode(saved))
        #expect(decoded.isSaved)
        #expect(decoded.id == saved.id)
    }
}
