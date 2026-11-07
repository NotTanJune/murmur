import MurmurDictionary
import Foundation
import Observation

/// The user's dictionary: the entries, the plain-text file that holds them, and the cached
/// corrector built from them.
///
/// `dictionary.txt` is meant to be edited by hand, so the store watches it and reloads on
/// outside changes. Its own writes are recognised by content and never reloaded.
@MainActor
@Observable
final class DictionaryStore {
    static let shared = DictionaryStore(fileURL: DictionaryStore.fileURL, starterText: DictionaryStore.bundledStarter)

    private(set) var entries: [DictionaryEntry] = []
    /// Bumped by every load and every save; the corrector cache is keyed on it.
    private(set) var revision = 0

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let starterText: () -> String
    @ObservationIgnored private var cachedCorrector: (revision: Int, corrector: DictionaryCorrector)?
    @ObservationIgnored private var watcher: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var isWatching = false
    /// Exact text of the last write or read, to tell our own file events from outside edits.
    @ObservationIgnored private var lastSyncedText: String?

    static var fileURL: URL {
        let directory = AppStorage.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("dictionary.txt")
    }

    /// The starter set shipped in the bundle; empty when the resource is missing, as in tests.
    nonisolated static func bundledStarter() -> String {
        guard let url = Bundle.main.url(forResource: "default-dictionary", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    init(fileURL: URL, starterText: @escaping () -> String) {
        url = fileURL
        self.starterText = starterText
        load()
        isWatching = true
        startWatching()
    }

    // MARK: Editing

    func add(_ entry: DictionaryEntry) {
        entries.append(entry)
        save()
    }

    func update(_ entry: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func delete(_ entry: DictionaryEntry) {
        delete(ids: [entry.id])
    }

    func delete(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func filtered(by query: String) -> [DictionaryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.write.localizedStandardContains(needle) || $0.hear.localizedStandardContains(needle)
        }
    }

    // MARK: Derived

    /// Compiled once per revision so rule compilation stays off the release path.
    var corrector: DictionaryCorrector {
        if let cached = cachedCorrector, cached.revision == revision { return cached.corrector }
        let built = DictionaryCorrector(entries: entries)
        cachedCorrector = (revision, built)
        return built
    }

    var biasPhrases: [String] {
        DictionaryCorrector.biasPhrases(from: entries)
    }

    // MARK: Loading and saving

    private func load() {
        revision += 1
        if FileManager.default.fileExists(atPath: url.path) {
            // An existing file always wins, even an empty one the user cleared on purpose.
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                entries = []
                return
            }
            entries = Self.parse(text)
            lastSyncedText = text
            return
        }
        let starter = Self.parse(starterText())
        guard !starter.isEmpty else {
            entries = []
            return
        }
        entries = starter
        save()
    }

    private static let header = """
        # Murmur dictionary
        #
        # One entry per line:
        #   Word or phrase      a term; speech recognition is biased toward this spelling.
        #   heard -> written    a correction; the heard text is rewritten after recognition.
        #   ## off: ...         put "# off: " before any entry to switch it off without deleting it.
        #
        # Changes made by hand are picked up automatically.

        """

    private func save() {
        revision += 1
        let text = Self.header + "\n" + entries.map(\.fileLine).joined(separator: "\n") + "\n"
        lastSyncedText = text
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        // The atomic write replaced the inode the watcher was attached to.
        if isWatching { startWatching() }
    }

    // MARK: Parsing

    /// Reads the file format. LF, CR LF and lone CR all end a line.
    static func parse(_ text: String) -> [DictionaryEntry] {
        let blanks = CharacterSet(charactersIn: " \t")
        var result: [DictionaryEntry] = []

        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            var body = rawLine.trimmingCharacters(in: blanks)
            guard !body.isEmpty else { continue }

            var isEnabled = true
            if body.hasPrefix("#") {
                let rest = String(body.dropFirst()).trimmingCharacters(in: blanks)
                guard let marker = rest.range(of: "off:", options: [.caseInsensitive, .anchored]) else { continue }
                body = String(rest[marker.upperBound...]).trimmingCharacters(in: blanks)
                guard !body.isEmpty else { continue }
                isEnabled = false
            }

            if let arrow = body.range(of: "->") {
                let hear = String(body[..<arrow.lowerBound]).trimmingCharacters(in: blanks)
                let write = String(body[arrow.upperBound...]).trimmingCharacters(in: blanks)
                guard !hear.isEmpty, !write.isEmpty else { continue }
                result.append(DictionaryEntry(kind: .correction, write: write, hear: hear, isEnabled: isEnabled))
            } else {
                result.append(DictionaryEntry(kind: .term, write: body, isEnabled: isEnabled))
            }
        }
        return result
    }

    // MARK: Watching

    /// Watches the file, replacing any previous watcher: every save swaps the inode, so a
    /// descriptor opened earlier stops reporting.
    private func startWatching() {
        watcher?.cancel()
        watcher = nil

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.fileChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func fileChanged() {
        defer { startWatching() }
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
           text == lastSyncedText {
            return
        }
        load()
    }
}
