import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MurmurDesign

/// Draws the trace over the HUD's colour at several moments of a synthetic sentence, for looking at.
/// Runs only with `MURMUR_TRACE_PREVIEW=<folder>`, as the swipe trail's preview does.
@MainActor
struct VoiceTracePreviewTests {
    @Test("Render preview frames when asked")
    func renderPreview() throws {
        guard let folder = ProcessInfo.processInfo.environment["MURMUR_TRACE_PREVIEW"] else { return }
        let source = VoiceTraceSource()
        // A sentence: room, then words of different loudness, one pause.
        let words: [(loud: Double, length: Double, gap: Double)] = [
            (-30, 0.28, 0.06), (-24, 0.45, 0.08), (-33, 0.2, 0.05), (-22, 0.5, 0.12), (-28, 0.3, 0.5), (-26, 0.4, 0.1),
        ]
        var time: TimeInterval = 5_000
        var snapshots: [(label: String, time: TimeInterval, trace: [Float])] = []
        func feed(_ dB: Double, seconds: Double) {
            for _ in 0..<Int((seconds / 0.01).rounded()) {
                time += 0.01
                let wobble = sin(time * 91) * 3
                source.ingest(rms: Float(pow(10, (dB + wobble) / 20)), at: time)
            }
        }
        feed(-75, seconds: 0.5)
        for (index, word) in words.enumerated() {
            feed(word.loud, seconds: word.length)
            feed(-75, seconds: word.gap)
            if index == 1 || index == 3 || index == 4 {
                snapshots.append(("word \(index + 1)", time, source.trace(points: DS.HUD.traceSegmentsPerSide, at: time)))
            }
        }
        feed(-75, seconds: 0.6)
        snapshots.append(("pause", time, source.trace(points: DS.HUD.traceSegmentsPerSide, at: time)))
        feed(-75, seconds: 1.2)
        snapshots.append(("late", time, source.trace(points: DS.HUD.traceSegmentsPerSide, at: time)))

        struct Sheet: View {
            let snapshots: [(label: String, time: TimeInterval, trace: [Float])]
            var body: some View {
                VStack(spacing: DS.HUD.margin) {
                    ForEach(Array(snapshots.enumerated()), id: \.offset) { _, snapshot in
                        Canvas { context, size in
                            VoiceTrace.draw(
                                values: snapshot.trace,
                                style: .init(tint: DS.Color.record, reduceMotion: false, time: snapshot.time),
                                in: &context,
                                size: size
                            )
                        }
                        .frame(width: DS.HUD.waveformWidth, height: DS.HUD.waveformHeight)
                        .frame(width: DS.HUD.width, height: DS.HUD.height)
                        .background(DS.Color.hud, in: .capsule)
                    }
                    Canvas { context, size in
                        VoiceTrace.draw(
                            values: [],
                            style: .init(tint: DS.Keyboard.waveformFlat, reduceMotion: false, time: 0),
                            in: &context,
                            size: size
                        )
                    }
                    .frame(width: DS.HUD.waveformWidth, height: DS.HUD.waveformHeight)
                    .frame(width: DS.HUD.width, height: DS.HUD.height)
                    .background(DS.Color.hud, in: .capsule)
                }
                .padding(DS.HUD.margin)
                .background(Color.gray.opacity(0.35))
            }
        }

        let renderer = ImageRenderer(content: Sheet(snapshots: snapshots))
        renderer.scale = 4
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("voice-trace.png"))
    }
}
