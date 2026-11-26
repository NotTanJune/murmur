import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MurmurDesign

/// Draws the trace at several moments of a synthetic sentence, at the Mac HUD's size over the HUD's
/// colour and at the phone capsule's size over its brown, for looking at. Runs only with
/// `MURMUR_TRACE_PREVIEW=<folder>`, as the swipe trail's preview does.
@MainActor
struct VoiceTracePreviewTests {
    private struct Moment {
        let label: String
        let time: TimeInterval
        let source: VoiceTraceSource
    }

    @Test("Render preview frames when asked")
    func renderPreview() throws {
        guard let folder = ProcessInfo.processInfo.environment["MURMUR_TRACE_PREVIEW"] else { return }
        // A sentence: room, then words of different loudness, one pause. A fresh source per
        // moment is cheaper to read than copying one, and the feed is deterministic.
        let words: [(loud: Double, length: Double, gap: Double)] = [
            (-30, 0.28, 0.06), (-24, 0.45, 0.08), (-33, 0.2, 0.05), (-22, 0.5, 0.12), (-28, 0.3, 0.5), (-26, 0.4, 0.1),
        ]
        func moment(_ label: String, after count: Int, extraSilence: Double) -> Moment {
            let source = VoiceTraceSource()
            var time: TimeInterval = 5_000
            func feed(_ dB: Double, seconds: Double) {
                for _ in 0..<Int((seconds / 0.01).rounded()) {
                    time += 0.01
                    let wobble = sin(time * 91) * 3
                    source.ingest(rms: Float(pow(10, (dB + wobble) / 20)), at: time)
                }
            }
            feed(-75, seconds: 0.5)
            for word in words.prefix(count) {
                feed(word.loud, seconds: word.length)
                feed(-75, seconds: word.gap)
            }
            if extraSilence > 0 { feed(-75, seconds: extraSilence) }
            return Moment(label: label, time: time, source: source)
        }
        let moments = [
            moment("word 2", after: 2, extraSilence: 0),
            moment("word 4", after: 4, extraSilence: 0),
            moment("mid word 6", after: 5, extraSilence: 0.25),
            moment("pause", after: 6, extraSilence: 0.6),
            moment("late", after: 6, extraSilence: 1.8),
        ]

        struct Frame: View {
            let moment: Moment?
            let pitch: CGFloat
            let areaWidth: CGFloat
            let areaHeight: CGFloat
            let capsuleWidth: CGFloat
            let capsuleHeight: CGFloat
            let background: Color
            let idleTint: Color

            var body: some View {
                let grid = VoiceTrace.Grid(size: CGSize(width: areaWidth, height: areaHeight), pitch: pitch)
                Canvas { context, _ in
                    let amplitudes = moment.map {
                        $0.source.amplitudes(count: grid.middleColumn + 1, seconds: DS.HUD.traceSeconds, at: $0.time)
                    } ?? []
                    VoiceTrace.draw(
                        amplitudes: amplitudes,
                        grid: grid,
                        style: .init(tint: DS.Color.record, idleTint: idleTint, reduceMotion: false, time: moment?.time ?? 0),
                        in: &context
                    )
                }
                .frame(width: areaWidth, height: areaHeight)
                .frame(width: capsuleWidth, height: capsuleHeight)
                .background(background, in: .capsule)
            }
        }

        struct Row: View {
            let moment: Moment?
            var body: some View {
                let phoneWidth: CGFloat = 236
                let phoneInset: CGFloat = DS.Keyboard.traceInset
                let phoneHeight: CGFloat = DS.Keyboard.recordingCapsuleHeight
                HStack(spacing: DS.HUD.margin) {
                    Frame(
                        moment: moment, pitch: DS.HUD.traceDotPitch,
                        areaWidth: DS.HUD.waveformWidth, areaHeight: DS.HUD.waveformHeight,
                        capsuleWidth: DS.HUD.width, capsuleHeight: DS.HUD.height,
                        background: DS.Color.hud, idleTint: DS.Color.record
                    )
                    Frame(
                        moment: moment, pitch: DS.Keyboard.traceDotPitch,
                        areaWidth: phoneWidth - 2 * phoneInset, areaHeight: phoneHeight,
                        capsuleWidth: phoneWidth, capsuleHeight: phoneHeight,
                        background: Color(.sRGB, red: 0x4A / 255, green: 0x3A / 255, blue: 0x2E / 255), idleTint: DS.Keyboard.waveformFlat
                    )
                }
            }
        }

        struct Sheet: View {
            let moments: [Moment]
            var body: some View {
                VStack(spacing: DS.HUD.margin) {
                    ForEach(moments, id: \.label) { moment in
                        Row(moment: moment)
                    }
                    Row(moment: nil)
                }
                .padding(DS.HUD.margin)
                .background(Color.gray.opacity(0.35))
            }
        }

        let renderer = ImageRenderer(content: Sheet(moments: moments))
        renderer.scale = 4
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("voice-trace-dots.png"))
    }
}
