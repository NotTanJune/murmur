import Foundation
import Testing
@testable import MurmurDictionary

/// Runs `dictionary-test-vectors.json`, the specification of `DictionaryCorrector.apply`,
/// and pins the smaller contracts of the dictionary target.
struct VectorTests {
    // MARK: Vector file

    private struct VectorFile: Decodable {
        let version: Int
        let cases: [VectorCase]
    }

    private struct VectorCase: Decodable {
        let name: String
        let entries: [VectorEntry]
        let input: String
        let expected: String
        let expectedCorrections: [VectorExpectation]
    }

    private struct VectorEntry: Decodable {
        let kind: String
        let hear: String?
        let write: String
        let isEnabled: Bool?

        var entry: DictionaryEntry {
            DictionaryEntry(
                kind: kind == "correction" ? .correction : .term,
                write: write,
                hear: hear ?? "",
                isEnabled: isEnabled ?? true
            )
        }
    }

    private struct VectorExpectation: Decodable {
        let to: String
        let count: Int
        let from: String?
    }

    private func loadVectors() throws -> VectorFile {
        let url = try #require(
            Bundle.module.url(forResource: "dictionary-test-vectors", withExtension: "json"),
            "dictionary-test-vectors.json is missing from the test bundle"
        )
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }

    private func scalars(_ text: String) -> [UInt32] {
        text.unicodeScalars.map(\.value)
    }

    private func escaped(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            scalar.isASCII && scalar.value >= 0x20 ? String(scalar) : "\\u{\(String(scalar.value, radix: 16))}"
        }.joined()
    }

    @Test("Every vector produces the expected text and corrections")
    func allVectors() throws {
        let file = try loadVectors()
        #expect(!file.cases.isEmpty, "The vector file holds no cases")

        for vector in file.cases {
            let corrector = DictionaryCorrector(entries: vector.entries.map(\.entry))
            let result = corrector.apply(to: vector.input)

            // By scalars, so a result left decomposed cannot hide behind Swift's canonical ==.
            #expect(
                scalars(result.text) == scalars(vector.expected),
                "\(vector.name): text was \"\(escaped(result.text))\", expected \"\(escaped(vector.expected))\""
            )

            let returned = result.applied.map { "\($0.to)x\($0.count)" }
            #expect(
                result.applied.count == vector.expectedCorrections.count,
                "\(vector.name): expected \(vector.expectedCorrections.count) corrections, got \(returned)"
            )

            var remaining = result.applied
            for expectation in vector.expectedCorrections {
                let found = remaining.firstIndex { candidate in
                    candidate.to == expectation.to
                        && candidate.count == expectation.count
                        && (expectation.from.map { $0 == candidate.from } ?? true)
                }
                #expect(
                    found != nil,
                    "\(vector.name): no correction to \"\(expectation.to)\" x\(expectation.count) from \(expectation.from ?? "any"); got \(remaining)"
                )
                if let found { remaining.remove(at: found) }
            }
        }
    }

    @Test("Vector names are unique")
    func uniqueNames() throws {
        let names = try loadVectors().cases.map(\.name)
        #expect(Set(names).count == names.count)
    }

    // MARK: Biasing

    @Test("Bias list is capped and deduplicated")
    func biasCapAndDedupe() {
        var entries = (0..<100).map { DictionaryEntry.term("word\($0)") }
        entries.append(.term("word0"))
        let phrases = DictionaryCorrector.biasPhrases(from: entries)
        #expect(phrases.count == DictionaryCorrector.biasLimit)
        #expect(Set(phrases).count == phrases.count)
    }

    @Test("Disabled entries are not used for biasing")
    func biasSkipsDisabled() {
        let entries = [
            DictionaryEntry(kind: .term, write: "Kelpie"),
            DictionaryEntry(kind: .term, write: "Hidden", isEnabled: false),
        ]
        #expect(DictionaryCorrector.biasPhrases(from: entries) == ["Kelpie"])
    }

    @Test("Bias dedupes case-insensitively, trims, skips blanks and keeps input order")
    func biasDetails() {
        let entries = [
            DictionaryEntry.term("  Zed  "),
            .term("zed"),
            .term("   "),
            .term("Alpha"),
            .term("ALPHA"),
        ]
        #expect(DictionaryCorrector.biasPhrases(from: entries) == ["Zed", "Alpha"])
    }

    @Test("A correction contributes its write text and never its hear text")
    func biasUsesWriteOnly() {
        let entries = [DictionaryEntry.correction(hear: "tail wind", write: "Tailwind")]
        #expect(DictionaryCorrector.biasPhrases(from: entries) == ["Tailwind"])
    }

    // MARK: Warnings

    @Test("An ordinary single word as a trigger produces a warning")
    func commonWordWarns() {
        let entry = DictionaryEntry.correction(hear: "file", write: "File")
        #expect(!DictionaryWarning.check(entry).isEmpty)
    }

    @Test("A distinctive two-word trigger produces no warnings")
    func distinctiveIsQuiet() {
        let entry = DictionaryEntry.correction(hear: "tail wind", write: "Tailwind")
        #expect(DictionaryWarning.check(entry).isEmpty)
    }

    @Test("A very short word that is not common gets the short warning")
    func shortWordWarns() {
        let entry = DictionaryEntry.correction(hear: "gpt", write: "GPT-5")
        #expect(DictionaryWarning.check(entry).count == 1)
    }

    @Test("A common word gets only the common-word warning, even when short")
    func commonWinsOverShort() {
        let short = DictionaryWarning.check(.correction(hear: "run", write: "Run it"))
        #expect(short.count == 1)
        let common = DictionaryWarning.check(.correction(hear: "file", write: "Archive"))
        #expect(common.count == 1)
    }

    @Test("Rewriting a trigger to itself warns, and may add to the word warning")
    func selfRewriteWarns() {
        let alone = DictionaryWarning.check(.correction(hear: "tail wind", write: " TAIL WIND "))
        #expect(alone.count == 1)
        let both = DictionaryWarning.check(.correction(hear: "a", write: "A"))
        #expect(both.count == 2)
        #expect(both[0].message != both[1].message)
    }

    @Test("Terms, hyphenated and multi-word triggers, and blank triggers never get the word warning")
    func quietCases() {
        #expect(DictionaryWarning.check(.term("file")).isEmpty)
        #expect(DictionaryWarning.check(.correction(hear: "the-file", write: "The File")).isEmpty)
        #expect(DictionaryWarning.check(.correction(hear: "red fox", write: "Fox")).isEmpty)
        #expect(DictionaryWarning.check(.correction(hear: "   ", write: "x")).isEmpty)
        #expect(DictionaryWarning.check(.correction(hear: "---", write: "x")).isEmpty)
    }

    @Test("A disabled entry is still checked")
    func disabledStillChecked() {
        let entry = DictionaryEntry(kind: .correction, write: "File", hear: "file", isEnabled: false)
        #expect(!DictionaryWarning.check(entry).isEmpty)
    }

    // MARK: Entries

    @Test("fileLine covers the four shapes")
    func fileLines() {
        #expect(DictionaryEntry.term("Kelpie").fileLine == "Kelpie")
        #expect(DictionaryEntry.correction(hear: "tail wind", write: "Tailwind").fileLine == "tail wind -> Tailwind")
        #expect(DictionaryEntry(kind: .term, write: "Kelpie", isEnabled: false).fileLine == "# off: Kelpie")
        #expect(
            DictionaryEntry(kind: .correction, write: "Tailwind", hear: "tail wind", isEnabled: false).fileLine
                == "# off: tail wind -> Tailwind"
        )
    }

    @Test("Kind raw values and the Codable keys are stable")
    func entryCoding() throws {
        #expect(DictionaryEntry.Kind.term.rawValue == "term")
        #expect(DictionaryEntry.Kind.correction.rawValue == "correction")

        let entry = DictionaryEntry(kind: .correction, write: "Tailwind", hear: "tail wind", isEnabled: false)
        let data = try JSONEncoder().encode(entry)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["id", "kind", "write", "hear", "isEnabled"])
        #expect(try JSONDecoder().decode(DictionaryEntry.self, from: data) == entry)
    }

    @Test("AppliedCorrection decodes and encodes its three keys")
    func appliedCorrectionCoding() throws {
        let json = Data(#"{"from":"cloud code","to":"Claude Code","count":2}"#.utf8)
        let decoded = try JSONDecoder().decode(AppliedCorrection.self, from: json)
        #expect(decoded.from == "cloud code")
        #expect(decoded.to == "Claude Code")
        #expect(decoded.count == 2)

        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(Set(object.keys) == ["from", "to", "count"])

        let missing = Data(#"{"from":"a","to":"b"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AppliedCorrection.self, from: missing) }
    }

    @Test("isEmpty reflects whether any rule survives")
    func isEmptyCases() {
        #expect(DictionaryCorrector(entries: []).isEmpty)
        #expect(DictionaryCorrector(entries: [.term("Kelpie")]).isEmpty)
        #expect(DictionaryCorrector(entries: [DictionaryEntry(kind: .correction, write: "A", hear: "a b", isEnabled: false)]).isEmpty)
        #expect(DictionaryCorrector(entries: [.correction(hear: "  ", write: "A")]).isEmpty)
        #expect(DictionaryCorrector(entries: [.correction(hear: "- -", write: "A")]).isEmpty)
        #expect(!DictionaryCorrector(entries: [.correction(hear: "a b", write: "A")]).isEmpty)
    }
}
