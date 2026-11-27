import SwiftUI

/// Three icons of the emoji picker's category bar that SF Symbols lacks. Apple's picker shows a
/// dog's face for Animals & Nature, an apple for Food & Drink and a small hatchback for Travel &
/// Places; those glyphs are private to iOS (none is in the SF Symbols app's 9,524 symbols on
/// 2026-11-27), and the nearest symbols (`dog`, `carrot`, `car.side`) are a dog in profile, a
/// carrot and a long saloon. These are
/// Murmur's own drawings of the same subjects, stroked at the weight of the bar's symbols
/// (`DS.Keyboard.emojiBarIconStroke`) and drawn in a unit square.

/// A dog's face from the front: a round head, two floppy ears, a patch over one eye, a nose
/// and a mouth.
public struct DogFaceIcon: View {
    public init() {}

    public var body: some View {
        ZStack {
            DogFaceLines()
                .stroke(style: StrokeStyle(lineWidth: DS.Keyboard.emojiBarIconStroke, lineCap: .round, lineJoin: .round))
            DogFaceFills()
                .fill(style: FillStyle(eoFill: true))
        }
        .frame(width: DS.Keyboard.emojiBarDrawnIconSize, height: DS.Keyboard.emojiBarDrawnIconSize)
        .accessibilityHidden(true)
    }
}

/// An apple with its stem and a leaf.
public struct AppleFruitIcon: View {
    public init() {}

    public var body: some View {
        AppleFruitShape()
            .stroke(style: StrokeStyle(lineWidth: DS.Keyboard.emojiBarIconStroke, lineCap: .round, lineJoin: .round))
            .frame(width: DS.Keyboard.emojiBarDrawnIconSize, height: DS.Keyboard.emojiBarDrawnIconSize)
            .accessibilityHidden(true)
    }
}

/// A small hatchback from the side: a short bonnet, a tall cabin with two windows, two wheels.
public struct CompactCarIcon: View {
    public init() {}

    public var body: some View {
        CompactCarShape()
            .stroke(style: StrokeStyle(lineWidth: DS.Keyboard.emojiBarIconStroke, lineCap: .round, lineJoin: .round))
            .frame(width: DS.Keyboard.emojiBarDrawnIconSize, height: DS.Keyboard.emojiBarDrawnIconSize)
            .accessibilityHidden(true)
    }
}

/// Maps unit-square coordinates into a rect.
private struct Unit {
    let rect: CGRect
    func callAsFunction(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }
}

struct DogFaceLines: Shape {
    func path(in rect: CGRect) -> Path {
        let p = Unit(rect: rect)
        var path = Path()
        // The head: wide at the cheeks, narrowing to the chin.
        path.move(to: p(0.5, 0.14))
        path.addCurve(to: p(0.80, 0.50), control1: p(0.70, 0.14), control2: p(0.80, 0.30))
        path.addCurve(to: p(0.5, 0.90), control1: p(0.80, 0.74), control2: p(0.68, 0.90))
        path.addCurve(to: p(0.20, 0.50), control1: p(0.32, 0.90), control2: p(0.20, 0.74))
        path.addCurve(to: p(0.5, 0.14), control1: p(0.20, 0.30), control2: p(0.30, 0.14))
        path.closeSubpath()
        // The ears hang from the top of the head and meet it again at the cheeks.
        path.move(to: p(0.32, 0.20))
        path.addCurve(to: p(0.04, 0.42), control1: p(0.16, 0.14), control2: p(0.04, 0.24))
        path.addCurve(to: p(0.13, 0.66), control1: p(0.04, 0.56), control2: p(0.07, 0.66))
        path.addCurve(to: p(0.21, 0.54), control1: p(0.18, 0.66), control2: p(0.20, 0.60))
        path.move(to: p(0.68, 0.20))
        path.addCurve(to: p(0.96, 0.42), control1: p(0.84, 0.14), control2: p(0.96, 0.24))
        path.addCurve(to: p(0.87, 0.66), control1: p(0.96, 0.56), control2: p(0.93, 0.66))
        path.addCurve(to: p(0.79, 0.54), control1: p(0.82, 0.66), control2: p(0.80, 0.60))
        // The mouth under the nose.
        path.move(to: p(0.5, 0.70))
        path.addLine(to: p(0.5, 0.75))
        path.move(to: p(0.40, 0.74))
        path.addQuadCurve(to: p(0.5, 0.75), control: p(0.44, 0.79))
        path.addQuadCurve(to: p(0.60, 0.74), control: p(0.56, 0.79))
        return path
    }
}

struct DogFaceFills: Shape {
    func path(in rect: CGRect) -> Path {
        let p = Unit(rect: rect)
        let w = rect.width
        var path = Path()
        // One eye plain, the other inside a patch; the even-odd fill leaves that eye as a hole.
        path.addEllipse(in: CGRect(center: p(0.38, 0.50), size: CGSize(width: 0.10 * w, height: 0.11 * w)))
        path.addEllipse(in: CGRect(center: p(0.625, 0.47), size: CGSize(width: 0.22 * w, height: 0.24 * w)))
        path.addEllipse(in: CGRect(center: p(0.62, 0.50), size: CGSize(width: 0.10 * w, height: 0.11 * w)))
        // The nose.
        path.addEllipse(in: CGRect(center: p(0.5, 0.65), size: CGSize(width: 0.17 * w, height: 0.11 * w)))
        return path
    }
}

struct AppleFruitShape: Shape {
    func path(in rect: CGRect) -> Path {
        let p = Unit(rect: rect)
        var path = Path()
        // The body: two shoulders either side of the stem's dip, a dimple at the base.
        path.move(to: p(0.5, 0.32))
        path.addCurve(to: p(0.88, 0.56), control1: p(0.64, 0.23), control2: p(0.88, 0.27))
        path.addCurve(to: p(0.65, 0.95), control1: p(0.88, 0.78), control2: p(0.77, 0.95))
        path.addCurve(to: p(0.5, 0.91), control1: p(0.58, 0.95), control2: p(0.55, 0.91))
        path.addCurve(to: p(0.35, 0.95), control1: p(0.45, 0.91), control2: p(0.42, 0.95))
        path.addCurve(to: p(0.12, 0.56), control1: p(0.23, 0.95), control2: p(0.12, 0.78))
        path.addCurve(to: p(0.5, 0.32), control1: p(0.12, 0.27), control2: p(0.36, 0.23))
        path.closeSubpath()
        // The stem.
        path.move(to: p(0.5, 0.32))
        path.addQuadCurve(to: p(0.46, 0.08), control: p(0.51, 0.16))
        // The leaf, to the right of the stem.
        path.move(to: p(0.51, 0.22))
        path.addQuadCurve(to: p(0.78, 0.06), control: p(0.56, 0.06))
        path.addQuadCurve(to: p(0.51, 0.22), control: p(0.76, 0.21))
        return path
    }
}

struct CompactCarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let p = Unit(rect: rect)
        let w = rect.width
        let wheel: CGFloat = 0.10
        var path = Path()
        // The body, from the front bumper round the roof to the tailgate, with an arch over
        // each wheel.
        path.move(to: p(0.17, 0.74))
        path.addLine(to: p(0.06, 0.74))
        path.addQuadCurve(to: p(0.06, 0.58), control: p(0.02, 0.66))
        path.addQuadCurve(to: p(0.32, 0.47), control: p(0.10, 0.49))
        path.addQuadCurve(to: p(0.56, 0.26), control: p(0.42, 0.29))
        path.addLine(to: p(0.80, 0.26))
        path.addQuadCurve(to: p(0.96, 0.52), control: p(0.94, 0.27))
        path.addLine(to: p(0.96, 0.66))
        path.addQuadCurve(to: p(0.90, 0.74), control: p(0.96, 0.74))
        path.addLine(to: p(0.86, 0.74))
        path.addArc(center: p(0.75, 0.74), radius: (wheel + 0.04) * w, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
        path.addLine(to: p(0.42, 0.74))
        path.addArc(center: p(0.28, 0.74), radius: (wheel + 0.04) * w, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
        // The wheels.
        path.addEllipse(in: CGRect(center: p(0.28, 0.76), size: CGSize(width: wheel * 2 * w, height: wheel * 2 * w)))
        path.addEllipse(in: CGRect(center: p(0.75, 0.76), size: CGSize(width: wheel * 2 * w, height: wheel * 2 * w)))
        // The two windows.
        path.move(to: p(0.40, 0.46))
        path.addQuadCurve(to: p(0.58, 0.33), control: p(0.47, 0.35))
        path.addLine(to: p(0.64, 0.33))
        path.addLine(to: p(0.64, 0.46))
        path.closeSubpath()
        path.move(to: p(0.71, 0.33))
        path.addLine(to: p(0.80, 0.33))
        path.addQuadCurve(to: p(0.87, 0.46), control: p(0.86, 0.34))
        path.addLine(to: p(0.71, 0.46))
        path.closeSubpath()
        return path
    }
}

private extension CGRect {
    init(center: CGPoint, size: CGSize) {
        self.init(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}
