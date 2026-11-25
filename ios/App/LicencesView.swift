import MurmurDesign
import SwiftUI

/// Settings → Licences: Murmur's own licence and the third-party components the iPhone app
/// links or downloads. Static text, kept in step with `THIRD_PARTY.md`.
struct LicencesView: View {
    var body: some View {
        PhonePage(title: "Licences") {
            Card(title: "Murmur") {
                Text("Murmur is free software under the GNU General Public License, version 3 only (GPL-3.0-only).")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                Note(text: "The source is available from the project's repository. This program comes with no warranty.")
            }

            Card(title: "Speech model") {
                entry(
                    "Underdog Bark 3.0 Clean",
                    license: "CC-BY-4.0",
                    detail: "Core ML build from FluidInference/bark-3.0-coreml, from Conway Research, derived from NVIDIA Parakeet TDT 0.6B v3 and Moondream parakeet-ultra. Downloaded to this iPhone on request; the upstream licence and notice files sit beside the weights."
                )
            }

            Card(title: "Typing model") {
                entry(
                    "DistilGPT2",
                    license: "Apache-2.0",
                    detail: "By Hugging Face, distilled from OpenAI's GPT-2. Converted to Core ML from distilbert/distilgpt2; suggests the next word on the keyboard when Smart predictions is on."
                )
            }

            Card(title: "Libraries") {
                entry(
                    "FluidAudio",
                    license: "Apache-2.0",
                    detail: "Runs the speech model on the Neural Engine. By Fluid Inference."
                )
            }

            Card(title: "Fonts") {
                entry(
                    "Fraunces",
                    license: "SIL Open Font License 1.1",
                    detail: "By Undercase Type, Phaedra Charles and Flavia Zimbardi."
                )
                FullLicence(resource: "OFL-Fraunces")
                entry(
                    "Figtree",
                    license: "SIL Open Font License 1.1",
                    detail: "By the Figtree Project Authors."
                )
                FullLicence(resource: "OFL-Figtree")
                entry(
                    "EB Garamond Italic",
                    license: "SIL Open Font License 1.1",
                    detail: "By Georg Duffner and Octavio Pardo. Sets the word \u{201C}Murmur\u{201D} on the keyboard's talk key."
                )
                FullLicence(resource: "OFL-EBGaramond")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func entry(_ name: String, license: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            HStack(spacing: DS.Space.snug) {
                Text(name)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                Tag(text: license)
            }
            Note(text: detail)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A licence text bundled with the app, hidden until asked for. The OFL requires its text to
/// travel with the fonts; the file is the one in `Resources/Fonts`.
private struct FullLicence: View {
    let resource: String

    @State private var isShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Button(isShown ? "Hide licence text" : "Show licence text") {
                withAnimation(DS.Motion.panel) { isShown.toggle() }
            }
            .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
            if isShown {
                Text(text)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var text: String {
        Bundle.main.url(forResource: resource, withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "The licence text is missing from this build."
    }
}
