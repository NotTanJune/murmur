import Foundation
import MurmurDictionary
import Testing
@testable import Murmur

/// Covers the file format only. `DictionaryStore.shared` reads and writes the real
/// Application Support folder, so these tests never touch it.
@MainActor
struct DictionaryStoreTests {
    private func parse(_ text: String) -> [DictionaryEntry] {
        DictionaryStore.parse(text)
    }

    @Test("Terms and corrections parse in file order")
    func termsAndCorrections() {
        let entries = parse("Kelpie\ntail wind -> Tailwind\n")
        #expect(entries.map(\.kind) == [.term, .correction])
        #expect(entries.map(\.write) == ["Kelpie", "Tailwind"])
        #expect(entries[1].hear == "tail wind")
        #expect(entries.allSatisfy { $0.isEnabled })
    }

    @Test("A correction needs no spaces around the arrow, and later arrows stay in write")
    func arrowSplit() {
        let tight = parse("a->b")
        #expect(tight.first?.hear == "a" && tight.first?.write == "b")
        let multiple = parse("x -> y -> z")
        #expect(multiple.first?.hear == "x")
        #expect(multiple.first?.write == "y -> z")
    }

    @Test("An empty half skips the whole line")
    func emptyHalves() {
        #expect(parse("-> b\na ->\n -> ").isEmpty)
    }

    @Test("Off lines parse in several spacings and cases")
    func offLines() {
        let text = "# off: Alpha\n#off:Beta\n#   OFF:   Gamma -> G\n\t# Off: Delta"
        let entries = parse(text)
        #expect(entries.map(\.write) == ["Alpha", "Beta", "G", "Delta"])
        #expect(entries.allSatisfy { !$0.isEnabled })
        #expect(entries[2].hear == "Gamma")
    }

    @Test("Comments, double-hash off lines and empty off bodies are skipped")
    func comments() {
        #expect(parse("# a comment\n## off: Hidden\n# off:\n#\n# off:   ").isEmpty)
    }

    @Test("A hash in the middle of a line is ordinary text")
    func midLineHash() {
        #expect(parse("C# language").first?.write == "C# language")
    }

    @Test("Spaces and tabs are trimmed and blank lines skipped")
    func trimming() {
        let entries = parse("  \t Kelpie \t\n\n   \n\tred fox\t->\t Fox  ")
        #expect(entries.map(\.write) == ["Kelpie", "Fox"])
        #expect(entries[1].hear == "red fox")
    }

    @Test("CR LF and lone CR end lines like LF")
    func lineEndings() {
        #expect(parse("One\r\nTwo\r\nThree").map(\.write) == ["One", "Two", "Three"])
        #expect(parse("One\rTwo\rThree").map(\.write) == ["One", "Two", "Three"])
        #expect(parse("One\r\n\r\nTwo\n\rThree").map(\.write) == ["One", "Two", "Three"])
    }

    @Test("Duplicates are kept")
    func duplicates() {
        #expect(parse("Kelpie\nKelpie").count == 2)
    }

    @Test("fileLine round-trips through parse")
    func roundTrip() {
        let originals = [
            DictionaryEntry.term("Kelpie"),
            .correction(hear: "tail wind", write: "Tailwind"),
            DictionaryEntry(kind: .term, write: "Hidden", isEnabled: false),
            DictionaryEntry(kind: .correction, write: "OAuth", hear: "oh auth", isEnabled: false),
        ]
        let parsed = parse(originals.map(\.fileLine).joined(separator: "\n"))
        #expect(parsed.count == originals.count)
        for (before, after) in zip(originals, parsed) {
            #expect(before.kind == after.kind)
            #expect(before.write == after.write)
            #expect(before.hear == after.hear)
            #expect(before.isEnabled == after.isEnabled)
        }
    }

    @Test("The starter file parses and every non-comment line yields an entry")
    func starterFile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Resources/default-dictionary.txt"), encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let entries = parse(text)
        #expect(!entries.isEmpty)
        #expect(entries.count == lines.count)
    }

    @Test("A store built on a temporary file saves, reloads and seeds the starter set")
    func storeLifecycle() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("dictionary.txt")

        let store = DictionaryStore(fileURL: file, starterText: { "Seed\nred fox -> Fox" })
        #expect(store.entries.map(\.write) == ["Seed", "Fox"])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(store.revision >= 1)

        let before = store.revision
        store.add(.term("Added"))
        #expect(store.revision > before)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved.hasSuffix("Added\n"))
        #expect(DictionaryStore.parse(saved).map(\.write) == ["Seed", "Fox", "Added"])

        let removed = store.entries[0]
        store.delete(removed)
        #expect(store.entries.map(\.write) == ["Fox", "Added"])
        #expect(store.filtered(by: " red ").map(\.write) == ["Fox"])
    }

    @Test("The saved header holds no entries")
    func headerIsInert() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("dictionary.txt")

        let store = DictionaryStore(fileURL: file, starterText: { "Seed" })
        store.delete(store.entries[0])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("#"))
        #expect(DictionaryStore.parse(text).isEmpty)
    }
}
