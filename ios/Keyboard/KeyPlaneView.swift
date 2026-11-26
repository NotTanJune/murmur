import MurmurDesign
import MurmurTyping
import UIKit

/// What the key plane draws: the current page's frames and the two things that change how a
/// key looks (shift, and the return key's job). The controller owns it and pushes a new value
/// whenever the engine or the field changes it.
struct KeyPlaneState: Equatable {
    var frames: [KeyFrame] = []
    var page: Page = .letters
    var shift: ShiftState = .off
    /// The word on the return key when the field names a job ("send", "go"); nil shows the glyph.
    var returnTitle: String?
    /// The field gave return a job other than a new line, so it is drawn blue as on Apple's.
    var returnProminent = false
    /// The strip above the plane, which the engine's coordinates include and this view does not.
    var stripHeight = DS.Keyboard.stripHeight
}

/// Every key of the keyboard, drawn and touched in one view.
///
/// Keys are `CALayer`s, not SwiftUI buttons: two thumbs typing quickly send overlapping touches,
/// and a SwiftUI `Button` arbitrates them one at a time. The project replaced SwiftUI with UIKit
/// for the emoji grid and the history list for the same reason (AGENTS.md). This view only
/// draws and forwards: each finger event goes to `onTouch` as a `TouchEvent`, the controller
/// feeds it to `TypingEngine`, and the effects come back as calls on this view (`state`,
/// `showPopup`, `hidePopup`, `setTrackpad`).
///
/// Where it lives. The view controller adds it as a direct subview of the keyboard's root view,
/// above the SwiftUI hosting view and pinned to the bottom, as tall as the keyboard less the
/// strip. It is not in the SwiftUI hierarchy: SwiftUI's own gesture handling on a hosting view
/// can delay or cancel a touch, and a cancelled character touch types nothing.
///
/// Coordinates. `KeyboardMetrics` places the strip in y 0 to `stripHeight` and the rows below
/// it, but the strip is SwiftUI and this view sits under it. The view therefore starts at
/// `stripHeight` in the engine's coordinates: touches are shifted down by it on the way in and
/// keycaps up by it on the way out, so the first row's hit rect (which reaches up through the
/// strip gap to the strip's edge) starts exactly at this view's top.
///
/// The pop-up is not drawn here. A first-row pop-up rises over the strip, which is outside this
/// view, so it lives on `popupHost`'s layer (the controller's root view) as one shape.
@MainActor
final class KeyPlaneView: UIView {
    /// The swipe trail's thickness, from Settings. The controller sets it at each touch-down.
    var swipeTrailWidth: CGFloat = DS.Keyboard.swipeTrailWidth

    /// Where finger events go. Set by `TypingController.attach`.
    var onTouch: ((TouchEvent) -> Void)?
    /// The globe key's touches, with the event the keyboard list needs.
    var onGlobe: ((UIView, UIEvent) -> Void)?
    /// The view whose layer carries the pop-up.
    weak var popupHost: UIView?

    var state = KeyPlaneState() {
        didSet { if state != oldValue { reload() } }
    }

    private struct KeyLayers {
        let kind: KeyKind
        let body: CALayer
        let glyph: CALayer?
    }

    private var keyLayers: [KeyLayers] = []
    private let globeButton = UIButton(type: .custom)
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 0
    /// Touch id to the kind of non-character key it holds, so the key shows pressed. A letter
    /// shows its pop-up instead.
    private var pressed: [Int: KeyKind] = [:]
    private var displayLink: CADisplayLink?
    private var trackpadActive = false
    private var popup: CALayer?
    /// The swipe's trail, above the keys: `SwipeTrail` gives the shape, drawn as a few faint
    /// filled copies over each other (`SwipeTrail.layers`) inside one layer that fades at lift.
    /// They are layers of this view, so they take no touches and cannot disturb the path.
    private let trailHost = CALayer()
    private let trailLayers = SwipeTrail.layers.map { _ in CAShapeLayer() }
    private var trailShape = SwipeTrail(configuration: SwipeTrail.Configuration(
        seconds: DS.Keyboard.swipeTrailSeconds, minimumStep: DS.Keyboard.swipeTrailMinimumStep,
        relaxRate: DS.Keyboard.swipeTrailRelaxRate))
    /// How many points of the controller's path the trail has taken, so an update that repeats
    /// the path adds nothing.
    private var trailTaken = 0
    /// The finger lifted and the trail is still running out: the display link stays on for it.
    private var trailIsDraining = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        // Never clear: see `touchBackingUIColor`. The gaps between keycaps must take touches.
        backgroundColor = DS.Keyboard.touchBackingUIColor
        isOpaque = false
        isAccessibilityElement = false
        globeButton.accessibilityLabel = "Next keyboard"
        globeButton.addTarget(self, action: #selector(globeEvent(_:event:)), for: .allTouchEvents)
        globeButton.addTarget(self, action: #selector(globeLanded), for: .touchDown)
        globeButton.isHidden = true
        addSubview(globeButton)
        for shape in trailLayers {
            shape.strokeColor = nil
            trailHost.addSublayer(shape)
        }
        // Above every key layer, which sit at zero and are rebuilt on each reload.
        trailHost.zPosition = 1
        layer.addSublayer(trailHost)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) {
            (view: KeyPlaneView, _) in view.reload()
        }
    }

    required init?(coder: NSCoder) { fatalError("KeyPlaneView is made in code") }

    // MARK: - Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The display scale is only known once the view has a window.
        if window != nil { reload() }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { cancelAllTouches() }
    }

    /// Ends every touch the engine still holds, as when the keyboard goes away mid-touch.
    func cancelAllTouches() {
        for (_, id) in touchIDs { onTouch?(.cancelled(id: id)) }
        touchIDs.removeAll()
        pressed.removeAll()
        hidePopup()
        trailTaken = 0
        clearTrail()
        stopTicking()
    }

    // MARK: - Drawing

    private var displayScale: CGFloat {
        let scale = traitCollection.displayScale
        return scale > 0 ? scale : (window?.screen.scale ?? 2)
    }

    private func resolved(_ color: UIColor) -> UIColor {
        color.resolvedColor(with: traitCollection)
    }

    private func fill(for kind: KeyKind) -> UIColor {
        if kind == .return, state.returnProminent { return resolved(DS.Keyboard.prominentUIKey) }
        return resolved(DS.Keyboard.keyUIColor)
    }

    /// Rebuilds every key. About thirty layers, and only on a page, shift, appearance or return
    /// key change, so it is cheaper than keeping each layer in step.
    private func reload() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in keyLayers { item.body.removeFromSuperlayer() }
        keyLayers = state.frames.map(makeLayers)
        for item in keyLayers { layer.addSublayer(item.body) }
        applyPressedAndTrackpad()
        let trailColor = resolved(DS.Keyboard.swipeTrailUIColor).cgColor
        for shape in trailLayers { shape.fillColor = trailColor }
        CATransaction.commit()
        updateGlobeButton()
        rebuildAccessibility()
    }

    private func makeLayers(for frame: KeyFrame) -> KeyLayers {
        let rect = frame.keycap.offsetBy(dx: 0, dy: -state.stripHeight)
        let body = CALayer()
        body.frame = rect
        body.cornerRadius = DS.Keyboard.keyRadius
        body.cornerCurve = .continuous
        body.backgroundColor = fill(for: frame.kind).cgColor
        let glyph = glyphLayer(for: frame.kind, size: rect.size)
        if let glyph { body.addSublayer(glyph) }
        return KeyLayers(kind: frame.kind, body: body, glyph: glyph)
    }

    /// What a letter key shows: lowercase unless shift or caps lock is on, as the iOS 26
    /// keyboard does. Shift applies on the letters page only.
    private func display(_ text: String) -> String {
        // The stock keyboard labels its quote keys with the typographic marks; what they type
        // is still decided by the field's smart-quote setting.
        if text == "\"" { return "\u{201D}" }
        if text == "'" { return "\u{2019}" }
        guard state.page == .letters, state.shift != .off, text.count == 1 else { return text }
        return text == "ß" ? "\u{1E9E}" : text.uppercased()
    }

    private func glyphLayer(for kind: KeyKind, size: CGSize) -> CALayer? {
        let label = resolved(DS.Keyboard.keyLabelUIColor)
        switch kind {
        case .character(let text):
            if state.page == .numberPad, let pad = numberPadGlyph(text, size: size) { return pad }
            let shown = display(text)
            let isLowercase = shown.count == 1 && shown.first.map { $0.isLetter && $0.isLowercase } == true
            // A key that types a word (".com") is labelled like "123", not like a letter. Digits
            // and symbols take the capitals' face: the stock keyboard sets them at its capital
            // height, and at the lowercase size they came out about 10% taller (2026-11-26).
            let font = shown.count > 1
                ? DS.Keyboard.labelUIFont
                : shown == "•" ? DS.Keyboard.bulletUIFont
                : isLowercase ? DS.Keyboard.letterUIFont : DS.Keyboard.capitalLetterUIFont
            return textLayer(shown, font: font, color: label, size: size)
        case .shift:
            let symbol = switch state.shift {
            case .off: "shift"
            case .on: "shift.fill"
            case .capsLock: "capslock.fill"
            }
            return iconLayer(symbol, color: label, size: size)
        case .delete:
            return iconLayer("delete.left", color: label, size: size)
        case .space:
            return nil
        case .return:
            let color = state.returnProminent ? resolved(DS.Keyboard.onProminentUIKey) : label
            if let title = state.returnTitle {
                return textLayer(title, font: DS.Keyboard.labelUIFont, color: color, size: size)
            }
            return iconLayer("return.left", color: color, size: size)
        case .pageSwitch(let page):
            let title = switch page {
            case .letters: "ABC"
            case .numbers: "123"
            case .symbols: "#+="
            case .numberPad: ""
            }
            let font = page == .symbols ? DS.Keyboard.symbolsSwitchUIFont : DS.Keyboard.labelUIFont
            return textLayer(title, font: font, color: label, size: size)
        case .emoji:
            return iconLayer("face.smiling", color: label, size: size)
        case .globe:
            return iconLayer("globe", color: label, size: size)
        }
    }

    /// The stock letters under each digit of the number pad.
    private static let numberPadLetters: [String: String] = [
        "2": "ABC", "3": "DEF", "4": "GHI", "5": "JKL", "6": "MNO", "7": "PQRS", "8": "TUV",
        "9": "WXYZ",
    ]

    /// A pad key: the digit in the larger face with its letters under it, or the digit alone
    /// (1, 0 and the decimal point) centred. Nil for a character the pad has no special look for.
    private func numberPadGlyph(_ text: String, size: CGSize) -> CALayer? {
        let rect = CGRect(origin: .zero, size: size)
        let label = resolved(DS.Keyboard.keyLabelUIColor)
        let digitFont = DS.Keyboard.numberPadDigitUIFont
        guard let letters = Self.numberPadLetters[text] else {
            return textLayer(text, font: digitFont, color: label, size: size)
        }
        let container = CALayer()
        container.frame = rect
        let digit = CATextLayer()
        digit.contentsScale = displayScale
        digit.alignmentMode = .center
        digit.string = NSAttributedString(
            string: text, attributes: [.font: digitFont, .foregroundColor: label])
        digit.frame = textFrame(for: text, font: digitFont, in: rect)
            .offsetBy(dx: 0, dy: -DS.Keyboard.numberPadDigitLift)
        let lettersFont = DS.Keyboard.numberPadLettersUIFont
        let under = CATextLayer()
        under.contentsScale = displayScale
        under.alignmentMode = .center
        under.string = NSAttributedString(
            string: letters,
            attributes: [
                .font: lettersFont, .foregroundColor: label,
                .kern: DS.Keyboard.numberPadLettersTracking,
            ])
        under.frame = textFrame(for: letters, font: lettersFont, in: rect)
            .offsetBy(dx: DS.Keyboard.numberPadLettersTracking / 2, dy: DS.Keyboard.numberPadLettersDrop)
        container.addSublayer(digit)
        container.addSublayer(under)
        return container
    }

    /// A line of text centred in a key. `CATextLayer` does not centre vertically, so the layer
    /// is one line tall and placed so the text's optical band sits on the key's centre
    /// (`textFrame`).
    private func textLayer(_ string: String, font: UIFont, color: UIColor, size: CGSize) -> CALayer {
        let text = CATextLayer()
        text.contentsScale = displayScale
        text.alignmentMode = .center
        text.string = NSAttributedString(
            string: string, attributes: [.font: font, .foregroundColor: color])
        text.frame = textFrame(for: string, font: font, in: CGRect(origin: .zero, size: size))
        return text
    }

    /// The height the eye centres a string by: the x-height for one lowercase letter, the cap
    /// height for everything else (capitals, digits, symbols and words such as `123`). The
    /// line box is not it: a face has far more room under the baseline than over the x-height,
    /// so a box-centred "a" sits low.
    private static func opticalBand(of string: String, font: UIFont) -> CGFloat {
        if string.count == 1, let character = string.first, character.isLetter, character.isLowercase {
            return font.xHeight
        }
        return font.capHeight
    }

    /// The frame of a text layer that puts the string's optical band on the vertical centre of
    /// `rect`. The baseline goes at the centre plus half the band; the layer draws its first
    /// baseline `ascender` below its top. Snapped to a pixel, so the baseline is crisp.
    private func textFrame(for string: String, font: UIFont, in rect: CGRect) -> CGRect {
        let baseline = rect.midY + Self.opticalBand(of: string, font: font) / 2
        let top = ((baseline - font.ascender) * displayScale).rounded() / displayScale
        return CGRect(x: rect.minX, y: top, width: rect.width, height: font.lineHeight.rounded(.up))
    }

    /// An SF Symbol drawn once into a bitmap in the label colour. A symbol image has no
    /// `cgImage` of its own, so it is rendered; the layer then needs no tint handling.
    private func iconLayer(_ name: String, color: UIColor, size: CGSize) -> CALayer? {
        let configuration = UIImage.SymbolConfiguration(pointSize: DS.Keyboard.iconPointSize)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        let image = UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in
            symbol.draw(at: .zero)
        }
        let icon = CALayer()
        icon.contents = image.cgImage
        icon.contentsScale = displayScale
        icon.bounds = CGRect(origin: .zero, size: symbol.size)
        icon.position = CGPoint(x: size.width / 2, y: size.height / 2)
        return icon
    }

    // MARK: - Pressed keys and the trackpad

    /// Special keys dim while a finger holds them; while the space bar is a trackpad every key
    /// fades and loses its glyph, so the keyboard reads as a surface and not as keys.
    private func applyPressedAndTrackpad() {
        let held = Set(pressed.values)
        for item in keyLayers {
            if trackpadActive {
                item.body.opacity = Float(1 - DS.Keyboard.trackpadKeyBlank)
                item.glyph?.isHidden = true
            } else {
                item.body.opacity = held.contains(item.kind) ? Float(DS.Keyboard.pressedOpacity) : 1
                item.glyph?.isHidden = false
            }
        }
    }

    func setTrackpad(_ active: Bool) {
        guard trackpadActive != active else { return }
        trackpadActive = active
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyPressedAndTrackpad()
        CATransaction.commit()
    }

    // MARK: - Globe

    /// The globe key is a real button over its hit rect. Only a `UIControl` hands the keyboard
    /// the `UIEvent` that `handleInputModeList(from:with:)` needs for the long press that lists
    /// keyboards. The plane draws its glyph; the button sits over it, takes its touches (so the
    /// engine never sees them) and is transparent.
    private func updateGlobeButton() {
        guard let globe = state.frames.first(where: { $0.kind == .globe }) else {
            globeButton.isHidden = true
            return
        }
        globeButton.frame = globe.hitRect.offsetBy(dx: 0, dy: -state.stripHeight)
        globeButton.isHidden = false
        bringSubviewToFront(globeButton)
    }

    @objc private func globeEvent(_ sender: UIButton, event: UIEvent) {
        onGlobe?(sender, event)
    }

    @objc private func globeLanded() {
        KeyFeedback.press()
    }

    // MARK: - Touches

    /// Draws nothing, on purpose. Overriding it gives the layer a bitmap the size of the plane,
    /// so the gaps between keycaps are drawn content (clear pixels) and not an empty layer. It
    /// is the second guard beside `touchBackingUIColor`, in case a nearly clear fill alone does
    /// not count as drawn for the system's touch routing.
    override func draw(_ rect: CGRect) {}

    /// A touch's position in the engine's coordinates, which start at the top of the strip.
    private func enginePoint(_ touch: UITouch) -> CGPoint {
        let point = touch.location(in: self)
        return CGPoint(x: point.x, y: point.y + state.stripHeight)
    }

    /// When the last finger landed on the plane, for `point(inside:with:)`.
    private var lastTouchDown: TimeInterval = -.infinity

    /// The plane also takes a touch that lands just above it, in the strip's lowest
    /// `typingStripReach` points, while typing is under way. The top row's own hit area ends at
    /// the plane's top edge, and a fast thumb overshoots it; without this the strip's SwiftUI
    /// view takes the touch and nothing is typed.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        guard point.y < 0, point.y >= -DS.Keyboard.typingStripReach,
            point.x >= bounds.minX, point.x <= bounds.maxX
        else { return false }
        let now = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        return now - lastTouchDown <= DS.Keyboard.typingStripReachSeconds
    }

    /// Touches of one event in a steady order, so two fingers that land together are typed in
    /// the order they came and not in a set's order.
    private func ordered(_ touches: Set<UITouch>) -> [UITouch] {
        touches.sorted { ($0.timestamp, $0.location(in: self).x) < ($1.timestamp, $1.location(in: self).x) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in ordered(touches) {
            let id = nextTouchID
            nextTouchID += 1
            touchIDs[ObjectIdentifier(touch)] = id
            // A touch taken from the strip (`point(inside:with:)`) lands on the top row's edge.
            var point = enginePoint(touch)
            if point.y < state.stripHeight {
                point.y = state.stripHeight
            }
            lastTouchDown = touch.timestamp
            // A key that types a word (".com") darkens like a function key: it gets no pop-up.
            if let frame = HitTester.key(at: point, frames: state.frames, bias: [:]),
                (frame.kind.characterValue?.count ?? 0) != 1
            {
                pressed[id] = frame.kind
                applyHighlight()
            }
            onTouch?(.began(id: id, point: point, time: touch.timestamp))
        }
        startTicking()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in ordered(touches) {
            guard let id = touchIDs[ObjectIdentifier(touch)] else { continue }
            onTouch?(.moved(id: id, point: enginePoint(touch), time: touch.timestamp))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in ordered(touches) {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            pressed[id] = nil
            onTouch?(.ended(id: id, point: enginePoint(touch), time: touch.timestamp))
        }
        applyHighlight()
        stopTickingIfIdle()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            pressed[id] = nil
            onTouch?(.cancelled(id: id))
        }
        applyHighlight()
        stopTickingIfIdle()
    }

    private func applyHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyPressedAndTrackpad()
        CATransaction.commit()
    }

    // MARK: - Ticks

    /// Holds (accents, the trackpad, delete repeats) fire without a finger moving, so the
    /// engine needs a clock while any finger is down: one event every 25 ms, in the common
    /// run-loop modes so a scroll in another view cannot starve it.
    private func startTicking() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(fireTick))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: DS.Keyboard.tickRateMinimum, maximum: DS.Keyboard.tickRateMaximum,
            preferred: DS.Keyboard.tickRate)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// The link runs while a finger is down (key repeat, the accent delay) and while a lifted
    /// swipe's trail runs out.
    private func stopTickingIfIdle() {
        if touchIDs.isEmpty, !trailIsDraining { stopTicking() }
    }

    @objc private func fireTick() {
        let now = ProcessInfo.processInfo.systemUptime
        if !touchIDs.isEmpty { onTouch?(.tick(time: now)) }
        // The trail moves at every frame, not only when the finger does: it thins with age and
        // relaxes behind the finger, and after the lift it runs out.
        if !trailShape.isEmpty { redrawTrail(at: now) }
        if trailIsDraining, trailShape.isEmpty { clearTrail() }
        stopTickingIfIdle()
    }

    // MARK: - Swipe trail

    /// Feeds the trail the swipe's path so far, in the engine's coordinates. The controller sends
    /// the whole path at each move; the view takes the points it has not seen. An empty path
    /// ends the swipe: the trail fades while it runs out.
    func setSwipePath(_ path: [CGPoint]) {
        guard !path.isEmpty else {
            guard !trailShape.isEmpty || trailTaken != 0 else { return }
            trailTaken = 0
            fadeTrail()
            return
        }
        if path.count < trailTaken || trailTaken == 0 {
            // A new swipe: whatever is left of the last one goes at once.
            trailGeneration += 1
            trailTaken = 0
            trailIsDraining = false
            trailShape.removeAll()
            trailHost.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            trailHost.opacity = 1
            CATransaction.commit()
        }
        let now = ProcessInfo.processInfo.systemUptime
        for point in path[trailTaken...] {
            trailShape.add(CGPoint(x: point.x, y: point.y - state.stripHeight), at: now)
        }
        trailTaken = path.count
        redrawTrail(at: now)
    }

    /// Counts swipes, so a fade that finishes after the next swipe began leaves its trail alone.
    private var trailGeneration = 0

    /// The finger lifted: the trail keeps running out towards where the finger left while the
    /// whole of it fades, so it does not stop dead and vanish.
    private func fadeTrail() {
        guard !trailShape.isEmpty else { return }
        trailGeneration += 1
        let generation = trailGeneration
        trailIsDraining = true
        startTicking()
        CATransaction.begin()
        CATransaction.setAnimationDuration(DS.Keyboard.swipeTrailFadeSeconds)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.trailGeneration == generation else { return }
            self.clearTrail()
        }
        trailHost.opacity = 0
        CATransaction.commit()
    }

    /// Takes the trail off at once and leaves the layers ready for the next swipe.
    private func clearTrail() {
        trailGeneration += 1
        trailIsDraining = false
        trailShape.removeAll()
        trailHost.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in trailLayers { shape.path = nil }
        trailHost.opacity = 1
        CATransaction.commit()
        stopTickingIfIdle()
    }

    private func redrawTrail(at now: TimeInterval) {
        trailShape.advance(to: now)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (shape, layer) in zip(trailLayers, SwipeTrail.layers) {
            shape.path = trailShape.path(
                at: now, headWidth: swipeTrailWidth, widthShare: layer.widthShare, spanShare: layer.spanShare)
        }
        CATransaction.commit()
    }

    // MARK: - Pop-up

    /// Shows the key's pop-up, or the accent row when `alternates` is not empty, as one shape on
    /// the host's layer. `selected` is the highlighted accent, nil when the finger left the row.
    func showPopup(
        _ kind: KeyKind, alternates: [String], selected: Int?, growsLeftward: Bool,
        cellWidth: CGFloat
    ) {
        hidePopup()
        // A pop-up is one large glyph; a key that types a word (".com") does not fit one.
        if alternates.isEmpty, (kind.characterValue?.count ?? 1) > 1 { return }
        guard let host = popupHost, let frame = state.frames.first(where: { $0.kind == kind })
        else { return }
        let key = convert(frame.keycap.offsetBy(dx: 0, dy: -state.stripHeight), to: host)
        let container = CALayer()
        // Above this plane's own layers, which sit at zero.
        container.zPosition = 1
        if alternates.isEmpty {
            addPreview(for: kind, key: key, bounds: host.bounds, to: container)
        } else {
            addAccentRow(
                alternates, selected: selected, key: key, bounds: host.bounds,
                growsLeftward: growsLeftward, cellWidth: cellWidth, to: container)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.layer.addSublayer(container)
        CATransaction.commit()
        popup = container
    }

    func hidePopup() {
        guard let popup else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        popup.removeFromSuperlayer()
        CATransaction.commit()
        self.popup = nil
    }

    /// A shape in the pop-up's fill with the floating shadow under it.
    private func shape(_ path: UIBezierPath, color: UIColor, shadow: Bool) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.path = path.cgPath
        shape.fillColor = resolved(color).cgColor
        if shadow {
            shape.shadowPath = path.cgPath
            shape.shadowColor = resolved(DS.Keyboard.popupShadowUIColor).cgColor
            shape.shadowOpacity = 1
            shape.shadowRadius = DS.Shadow.floatRadius
            shape.shadowOffset = CGSize(width: 0, height: DS.Shadow.floatY)
        }
        return shape
    }

    /// The key's preview: the keycap widened above itself and joined to it by two curves, so it
    /// reads as the key rising out of the keyboard. One path, so there is no seam to see. The
    /// head is kept inside the host's width, which shifts it on the outermost keys, and inside
    /// its top, which shortens a first-row head by the strip gap's worth.
    private func addPreview(for kind: KeyKind, key: CGRect, bounds: CGRect, to container: CALayer) {
        let radius = DS.Keyboard.keyRadius
        let neck = DS.Keyboard.popupNeckRadius
        let width = key.width * DS.Keyboard.popupWidthScale
        let left = min(max(key.midX - width / 2, bounds.minX), bounds.maxX - width)
        let right = left + width
        let top = max(key.minY - DS.Keyboard.popupHeight, bounds.minY)
        let join = key.minY
        let path = UIBezierPath()
        path.move(to: CGPoint(x: left + radius, y: top))
        path.addLine(to: CGPoint(x: right - radius, y: top))
        path.addArc(
            withCenter: CGPoint(x: right - radius, y: top + radius), radius: radius,
            startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: right, y: join - neck))
        path.addQuadCurve(
            to: CGPoint(x: key.maxX, y: join + neck), controlPoint: CGPoint(x: right, y: join))
        path.addLine(to: CGPoint(x: key.maxX, y: key.maxY - radius))
        path.addArc(
            withCenter: CGPoint(x: key.maxX - radius, y: key.maxY - radius), radius: radius,
            startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: key.minX + radius, y: key.maxY))
        path.addArc(
            withCenter: CGPoint(x: key.minX + radius, y: key.maxY - radius), radius: radius,
            startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: key.minX, y: join + neck))
        path.addQuadCurve(
            to: CGPoint(x: left, y: join - neck), controlPoint: CGPoint(x: left, y: join))
        path.addLine(to: CGPoint(x: left, y: top + radius))
        path.addArc(
            withCenter: CGPoint(x: left + radius, y: top + radius), radius: radius,
            startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: true)
        path.close()
        container.addSublayer(shape(path, color: DS.Keyboard.popupUIFill, shadow: true))

        let glyph = kind.characterValue.map(display) ?? ""
        let head = CGRect(x: left, y: top, width: width, height: join - top)
        container.addSublayer(
            popupText(glyph, font: DS.Keyboard.popupUIFont, color: DS.Keyboard.keyLabelUIColor, in: head))
    }

    /// The accent row: one rounded bar above the key with a cell per accent. Entry 0 is the
    /// cell nearest the key, so a row that grows leftward lists its entries right to left.
    private func addAccentRow(
        _ alternates: [String], selected: Int?, key: CGRect, bounds: CGRect,
        growsLeftward: Bool, cellWidth: CGFloat, to container: CALayer
    ) {
        let total = cellWidth * CGFloat(alternates.count)
        var left = growsLeftward ? key.maxX - total : key.minX
        left = min(max(left, bounds.minX), max(bounds.maxX - total, bounds.minX))
        let top = max(key.minY - DS.Keyboard.popupHeight, bounds.minY)
        let row = CGRect(x: left, y: top, width: total, height: key.minY - top)
        let bar = UIBezierPath(roundedRect: row, cornerRadius: DS.Keyboard.keyRadius)
        container.addSublayer(shape(bar, color: DS.Keyboard.popupUIFill, shadow: true))

        for (index, accent) in alternates.enumerated() {
            let x = growsLeftward ? left + total - CGFloat(index + 1) * cellWidth : left + CGFloat(index) * cellWidth
            let cell = CGRect(x: x, y: row.minY, width: cellWidth, height: row.height)
            let isSelected = index == selected
            if isSelected {
                let inset = DS.Keyboard.popupCellInset
                let highlight = UIBezierPath(
                    roundedRect: cell.insetBy(dx: inset, dy: inset),
                    cornerRadius: max(DS.Keyboard.keyRadius - inset, 0))
                container.addSublayer(shape(highlight, color: DS.Keyboard.popupSelectedUIFill, shadow: false))
            }
            container.addSublayer(
                popupText(
                    accent, font: DS.Keyboard.accentUIFont,
                    color: isSelected ? DS.Keyboard.popupSelectedUILabel : DS.Keyboard.keyLabelUIColor,
                    in: cell))
        }
    }

    private func popupText(_ string: String, font: UIFont, color: UIColor, in rect: CGRect) -> CATextLayer {
        let text = CATextLayer()
        text.contentsScale = displayScale
        text.alignmentMode = .center
        text.string = NSAttributedString(
            string: string, attributes: [.font: font, .foregroundColor: resolved(color)])
        text.frame = textFrame(for: string, font: font, in: rect)
        return text
    }

    // MARK: - Accessibility

    /// A key as VoiceOver sees it. Activating it sends the touch pair a finger would, so the
    /// engine's rules (shift, pages, the return key) apply to VoiceOver too. The trackpad needs
    /// a held finger, so it cannot start this way, and nothing here swipes.
    private final class KeyElement: UIAccessibilityElement {
        var onActivate: (() -> Void)?
        override func accessibilityActivate() -> Bool {
            onActivate?()
            return true
        }
    }

    private func rebuildAccessibility() {
        var elements: [Any] = state.frames.compactMap { frame -> Any? in
            // The globe is the button over it, which VoiceOver already reaches.
            guard frame.kind != .globe else { return nil }
            let element = KeyElement(accessibilityContainer: self)
            element.accessibilityLabel = label(for: frame.kind)
            element.accessibilityValue = value(for: frame.kind)
            element.accessibilityTraits = .keyboardKey
            element.accessibilityFrameInContainerSpace =
                frame.keycap.offsetBy(dx: 0, dy: -state.stripHeight)
            element.onActivate = { [weak self] in self?.activate(frame) }
            return element
        }
        if !globeButton.isHidden { elements.append(globeButton) }
        accessibilityElements = elements
    }

    private func label(for kind: KeyKind) -> String {
        switch kind {
        case .character(let text): display(text)
        case .shift: "Shift"
        case .delete: "Delete"
        case .space: "Space"
        case .return: state.returnTitle ?? "Return"
        case .pageSwitch(let page):
            switch page {
            case .letters: "Letters"
            case .numbers: "Numbers"
            case .symbols: "Symbols"
            case .numberPad: "Number pad"
            }
        case .emoji: "Emoji"
        case .globe: "Next keyboard"
        }
    }

    private func value(for kind: KeyKind) -> String? {
        guard kind == .shift else { return nil }
        switch state.shift {
        case .off: return nil
        case .on: return "On"
        case .capsLock: return "Caps lock"
        }
    }

    private func activate(_ frame: KeyFrame) {
        let point = CGPoint(x: frame.keycap.midX, y: frame.keycap.midY)
        let id = nextTouchID
        nextTouchID += 1
        let now = ProcessInfo.processInfo.systemUptime
        onTouch?(.began(id: id, point: point, time: now))
        onTouch?(.ended(id: id, point: point, time: now))
    }
}
