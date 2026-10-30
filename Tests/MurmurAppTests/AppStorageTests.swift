import Foundation
import Testing
@testable import Murmur

struct AppStorageTests {
    @Test("Migration preserves dictionary and history bytes and leaves originals intact")
    func preservesFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("old")
        let destination = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let dictionary = Data("custom spelling\n".utf8)
        let history = Data("{\"engine\":\"Apple (streaming)\"}\n".utf8)
        try dictionary.write(to: source.appendingPathComponent("dictionary.txt"))
        try history.write(to: source.appendingPathComponent("runs.jsonl"))
        try AppStorage.migrateFiles(from: source, to: destination)
        for name in ["dictionary.txt", "runs.jsonl"] {
            #expect(try Data(contentsOf: source.appendingPathComponent(name)) == Data(contentsOf: destination.appendingPathComponent(name)))
        }
    }

    @Test("Migration never replaces an existing destination, including an empty dictionary")
    func existingFilesWin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("old")
        let destination = root.appendingPathComponent("new")
        for directory in [source, destination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("old words".utf8).write(to: source.appendingPathComponent("dictionary.txt"))
        try Data().write(to: destination.appendingPathComponent("dictionary.txt"))
        try AppStorage.migrateFiles(from: source, to: destination)
        try AppStorage.migrateFiles(from: source, to: destination)
        #expect(try Data(contentsOf: destination.appendingPathComponent("dictionary.txt")).isEmpty)
    }

    @Test("A later launch does not resurrect history cleared after migration")
    func migrationRunsOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("old")
        let destination = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("old history".utf8).write(to: source.appendingPathComponent("runs.jsonl"))
        try AppStorage.migrateFiles(from: source, to: destination)
        try FileManager.default.removeItem(at: destination.appendingPathComponent("runs.jsonl"))
        try AppStorage.migrateFiles(from: source, to: destination)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("runs.jsonl").path))
    }

    @Test("First installation succeeds without a legacy data directory")
    func noLegacyData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try AppStorage.migrateFiles(from: root.appendingPathComponent("missing"), to: root.appendingPathComponent("new"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
    }
}
