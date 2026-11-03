import AVFoundation
import Foundation

/// The audio behind each history run, one FLAC per run, for training exports.
///
/// Written on `RunLog`'s queue at delivery and deleted whenever the run is pruned or
/// deleted, so the folder never outgrows history. FLAC through `AVAudioFile` keeps the
/// 16 kHz capture lossless at about 1 MB per minute.
struct RecordingStore: Sendable {
    let directory: URL

    static let shared = RecordingStore(
        directory: AppStorage.directory.appendingPathComponent("Recordings", isDirectory: true)
    )

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).flac")
    }

    func exists(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    /// Writes the buffers in capture order. Buffers are converted from their own format
    /// (float32 or int16, whatever the engine asked capture for) by `AVAudioFile`.
    func write(_ chunks: [AudioChunk], id: UUID) throws {
        guard let first = chunks.first(where: { $0.buffer.frameLength > 0 }) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = first.buffer.format
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
        ]
        let file = try AVAudioFile(
            forWriting: url(for: id), settings: settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
        for chunk in chunks where chunk.buffer.frameLength > 0 {
            try file.write(from: chunk.buffer)
        }
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    func totalBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
