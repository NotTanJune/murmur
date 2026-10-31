import Foundation
import Testing
@testable import Murmur

@Suite struct CompileCacheGuardTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A real cache folder is moved to the safe place and replaced by a link; a purge of the link is repaired")
    func movesThenRelinks() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("Caches/app/com.apple.e5rt.e5bundlecache", isDirectory: true)
        let safe = root.appendingPathComponent("Support/ane-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: link.appendingPathComponent("26B123/abc"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: link.appendingPathComponent("26B123/abc/model.milhash"))

        #expect(try CompileCacheGuard.ensure(link: link, safe: safe) == .moved)
        #expect(FileManager.default.fileExists(atPath: safe.appendingPathComponent("26B123/abc/model.milhash").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == safe.path)
        // Reading through the link reaches the moved file.
        #expect(FileManager.default.fileExists(atPath: link.appendingPathComponent("26B123/abc/model.milhash").path))
        #expect(try CompileCacheGuard.ensure(link: link, safe: safe) == .alreadyLinked)

        try FileManager.default.removeItem(at: link)    // what a purge does
        #expect(try CompileCacheGuard.ensure(link: link, safe: safe) == .linked)
        #expect(FileManager.default.fileExists(atPath: link.appendingPathComponent("26B123/abc/model.milhash").path))
    }

    @Test("Compile leftovers from dead processes are removed; live ones and real bundles stay")
    func prunesAbandonedCompiles() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let hash = root.appendingPathComponent("26B123/abc")
        for name in ["real.bundle", "real.tmp.111_5.bundle", "real.tmp.222_6.bundle"] {
            try FileManager.default.createDirectory(at: hash.appendingPathComponent(name).appendingPathComponent("H14G.bundle"), withIntermediateDirectories: true)
        }
        let removed = try CompileCacheGuard.pruneAbandonedCompiles(in: root, isAlive: { $0 == 222 })
        #expect(removed == 1)
        #expect(FileManager.default.fileExists(atPath: hash.appendingPathComponent("real.bundle").path))
        #expect(FileManager.default.fileExists(atPath: hash.appendingPathComponent("real.tmp.222_6.bundle").path))
        #expect(!FileManager.default.fileExists(atPath: hash.appendingPathComponent("real.tmp.111_5.bundle").path))
    }
}
