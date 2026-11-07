import Foundation
import SQLite3

/// Returns Wispr Flow's own result for the utterance just spoken, so it can be shown beside
/// the local engines. Wispr has no API; its local `History` table, which holds the raw
/// recognition text, the cleaned text and the latency, is the only source. Raw versus
/// cleaned mirrors this app's split between engine and formatter. Access is read only: the
/// file belongs to Wispr and is never written, locked, copied or moved.
enum WisprReader {
    /// Stored in history rows (`DictationRun.engine`) and used to tell Wispr's row from the
    /// local ones, so the text must not change.
    static let engineName = "Wispr Flow"

    static var databaseURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("Wispr Flow", isDirectory: true)
            .appendingPathComponent("flow.sqlite")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    private static let pollInterval: Duration = .milliseconds(300)
    private static let matchWindow: TimeInterval = 5
    private static let timestampLength = 23

    /// The row Wispr wrote for the hold that began at `holdStarted`, polled until `timeout`
    /// seconds have passed. Nil when Wispr is not installed or never produced text; that is
    /// the ordinary outcome when its hotkey was not pressed, not an error.
    static func result(after holdStarted: Date, timeout: TimeInterval) async -> ComparisonResult? {
        guard isInstalled else { return nil }

        // Wispr stamps the row at the start of its utterance, and the two hotkeys are never
        // pressed in the same millisecond, so the row is often a little older than our hold.
        // The upper bound matters too: Wispr inserts the row empty and fills it in later, so
        // an open-ended search would return the previous dictation's row on the first poll.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let lower = formatter.string(from: holdStarted.addingTimeInterval(-matchWindow))
        let upper = formatter.string(from: holdStarted.addingTimeInterval(matchWindow))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        // Cloud cleanup finishes after both local engines, hence polling.
        while true {
            if Task.isCancelled { return nil }
            if let row = readRow(after: lower, before: upper) { return row }
            if clock.now >= deadline { return nil }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return nil
            }
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func readRow(after lower: String, before upper: String) -> ComparisonResult? {
        // Wispr rewrites the file while we poll, so a fresh connection per poll, and no
        // `immutable=1`, which would cache the file and hide those rows. The path has a
        // space and may hold characters special in SQLite URIs, so encode it.
        guard let encoded = databaseURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        let uri = "file://\(encoded)?mode=ro"

        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            return nil
        }

        let sql = """
            SELECT COALESCE(NULLIF(formattedText, ''), NULLIF(asrText, '')) AS text,
                   COALESCE(e2eLatency, 0)
            FROM History
            WHERE substr(timestamp, 1, \(timestampLength)) > ?1
              AND substr(timestamp, 1, \(timestampLength)) < ?2
              AND COALESCE(NULLIF(formattedText, ''), NULLIF(asrText, '')) IS NOT NULL
            ORDER BY substr(timestamp, 1, \(timestampLength)) DESC
            LIMIT 1
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, lower, -1, transient)
        sqlite3_bind_text(statement, 2, upper, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let cString = sqlite3_column_text(statement, 0) else {
            return nil
        }

        let text = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Wispr's own end-to-end latency: it includes a network round trip and the cloud
        // cleanup pass, so it is not comparable with the local compute times. The comparison
        // window keeps this row out of the speed ranking (decision D1 of the rewrite spec).
        let seconds = sqlite3_column_double(statement, 1) / 1000
        return ComparisonResult(engine: engineName, text: text, seconds: seconds)
    }
}
