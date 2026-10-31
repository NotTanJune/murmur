import Darwin
import Foundation

/// Keeps Core ML's Neural Engine compile cache where macOS won't purge it.
///
/// Core ML writes compiled ANE programs under `~/Library/Caches/<bundle id>/
/// com.apple.e5rt.e5bundlecache`, keyed by OS build and model hash, and there is no API to
/// move it. On 2026-10-31 macOS dropped that folder and Bark's next load recompiled for
/// 157 s. `Caches` is purgeable; `Application Support` is not. So the real folder lives
/// under Murmur's Application Support and the Caches path is a symlink to it. A purge can
/// only remove the link, which `ensure()` recreates before the first model load. Measured:
/// loads through the link cost the same (0.3–0.4 s) and survive deleting the link.
///
/// Also removes `*.tmp.<pid>_*` bundles whose process is gone: a compile killed partway
/// (a quit during the first load) leaves 400 MB behind, and nothing else cleans it.
enum CompileCacheGuard {
    static let cacheName = "com.apple.e5rt.e5bundlecache"

    static var safeDirectory: URL {
        AppStorage.directory.appendingPathComponent("Models/ane-cache", isDirectory: true)
    }

    static var cacheLink: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "ai.pivotstudio.murmur"
        return caches.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent(cacheName, isDirectory: true)
    }

    /// Call before any Core ML load. Idempotent; never throws past a log line, because a
    /// failure here only costs a recompile, not a dictation.
    static func ensure() {
        do {
            let action = try ensure(link: cacheLink, safe: safeDirectory)
            if action != .alreadyLinked {
                Log.app.info("compile cache: \(action.rawValue, privacy: .public)")
            }
            let pruned = try pruneAbandonedCompiles(in: safeDirectory)
            if pruned > 0 { Log.app.info("compile cache: removed \(pruned) abandoned compile folders") }
        } catch {
            Log.app.error("compile cache guard failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    enum Action: String, Equatable {
        case alreadyLinked = "already linked"
        case linked = "linked Caches to Application Support"
        case moved = "moved existing cache to Application Support and linked"
        case merged = "merged existing cache into Application Support and linked"
    }

    /// Testable core: makes `link` a symlink to `safe`, carrying over whatever a real
    /// folder at `link` held.
    @discardableResult
    static func ensure(link: URL, safe: URL) throws -> Action {
        let fm = FileManager.default
        try fm.createDirectory(at: safe, withIntermediateDirectories: true)
        try? (safe as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)

        var isDirectory: ObjCBool = false
        let attributes = try? fm.attributesOfItem(atPath: link.path)
        let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink

        if isSymlink {
            if let target = try? fm.destinationOfSymbolicLink(atPath: link.path),
               URL(fileURLWithPath: target).standardizedFileURL.path == safe.standardizedFileURL.path {
                return .alreadyLinked
            }
            try fm.removeItem(at: link)
        }

        var action = Action.linked
        if !isSymlink, fm.fileExists(atPath: link.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                // Keep what's already compiled: move it, or merge it if the safe folder has
                // its own contents (the OS build folders then coexist).
                if try fm.contentsOfDirectory(atPath: safe.path).isEmpty {
                    try fm.removeItem(at: safe)
                    try fm.moveItem(at: link, to: safe)
                    action = .moved
                } else {
                    for name in try fm.contentsOfDirectory(atPath: link.path) {
                        let destination = safe.appendingPathComponent(name)
                        if !fm.fileExists(atPath: destination.path) {
                            try fm.moveItem(at: link.appendingPathComponent(name), to: destination)
                        }
                    }
                    try fm.removeItem(at: link)
                    action = .merged
                }
            } else {
                try fm.removeItem(at: link)
            }
        }

        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: safe)
        return action
    }

    /// Removes `<hash>.tmp.<pid>_<n>.bundle` folders left by compiles whose process has
    /// exited. Core ML names them with the compiling pid, so a live one is left alone.
    @discardableResult
    static func pruneAbandonedCompiles(in root: URL, isAlive: (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) throws -> Int {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return 0 }
        var removed = 0
        var victims: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasSuffix(".bundle"), let range = name.range(of: ".tmp.") else { continue }
            let rest = name[range.upperBound...]
            guard let pidText = rest.split(separator: "_").first, let pid = pid_t(pidText) else { continue }
            if !isAlive(pid) {
                victims.append(url)
                walker.skipDescendants()
            }
        }
        for url in victims {
            try fm.removeItem(at: url)
            removed += 1
        }
        return removed
    }
}
