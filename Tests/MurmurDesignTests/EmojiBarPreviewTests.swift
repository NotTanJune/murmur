import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MurmurDesign

/// Draws the emoji picker's category bar as the keyboard lays it out on a 393 pt phone, at 3x
/// over the dark keyboard's ground, for comparing with a screenshot of Apple's. A second row
/// swaps the drawn icons for the nearest SF Symbols (`dog`, `carrot`, `car.side`). Runs only with
/// `MURMUR_EMOJI_BAR_PREVIEW=<folder>`.
@MainActor
struct EmojiBarPreviewTests {
    private enum Icon {
        case symbol(String)
        case dog
        case apple
        case car
    }

    private struct Bar: View {
        let icons: [Icon]

        var body: some View {
            HStack(spacing: 0) {
                Text("ABC")
                    .font(DS.Keyboard.emojiBarABCFont)
                    .opacity(DS.Keyboard.emojiBarABCOpacity)
                    .padding(.leading, DS.Keyboard.emojiBarABCInset)
                    .frame(width: DS.Keyboard.emojiBarSideWidth, alignment: .leading)
                ForEach(Array(icons.enumerated()), id: \.offset) { index, icon in
                    Group {
                        switch icon {
                        case .symbol(let name): Image(systemName: name).font(DS.Keyboard.barIconFont)
                        case .dog: DogFaceIcon()
                        case .apple: AppleFruitIcon()
                        case .car: CompactCarIcon()
                        }
                    }
                    .frame(maxWidth: DS.Keyboard.emojiBarSelectionDiameter, maxHeight: DS.Keyboard.emojiBarSelectionDiameter)
                    .background(Circle().fill(index == 0 ? Color(white: 64 / 255) : .clear))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Image(systemName: "delete.left")
                    .font(DS.Keyboard.emojiBarDeleteFont)
                    .opacity(DS.Keyboard.emojiBarDeleteOpacity)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, DS.Keyboard.emojiBarDeleteInset)
                    .frame(width: DS.Keyboard.emojiBarSideWidth)
            }
            .foregroundStyle(.white)
            .frame(width: 393 - DS.Keyboard.padding * 2, height: DS.Keyboard.emojiBarHeight)
            .padding(.horizontal, DS.Keyboard.padding)
            .padding(.vertical, 5)
            .background(Color(white: 36 / 255))
            .environment(\.colorScheme, .dark)
        }
    }

    @Test("Render the category bar when asked")
    func renderPreview() throws {
        guard let folder = ProcessInfo.processInfo.environment["MURMUR_EMOJI_BAR_PREVIEW"] else { return }
        let tail: [Icon] = [.symbol("lightbulb"), .symbol("heart"), .symbol("flag")]
        let drawn: [Icon] = [.symbol("clock"), .symbol("face.smiling"), .dog, .apple, .symbol("soccerball"), .car] + tail
        let symbols: [Icon] = [.symbol("clock"), .symbol("face.smiling.inverse"), .symbol("dog"), .symbol("carrot"), .symbol("soccerball"), .symbol("car.side")] + tail
        let sheet = VStack(spacing: 0) {
            Bar(icons: drawn)
            Bar(icons: symbols)
        }
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 3
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("emoji-bar.png"))
    }
}
