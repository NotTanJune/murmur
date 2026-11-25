import CoreGraphics
import Foundation

/// One finger event from the key plane. Times are in the caller's monotonic clock, in seconds;
/// the engine has no clock of its own, so a test drives it with made-up times.
public enum TouchEvent: Sendable {
    case began(id: Int, point: CGPoint, time: TimeInterval)
    case moved(id: Int, point: CGPoint, time: TimeInterval)
    case ended(id: Int, point: CGPoint, time: TimeInterval)
    case cancelled(id: Int)
    /// The view sends one every 25 ms while any touch is down, so holds and repeats fire even
    /// when no finger moves.
    case tick(time: TimeInterval)
}

/// What the controller should do after an event. The engine never sees the text, so every effect
/// is a plain instruction.
public enum TypingEffect: Equatable, Sendable {
    /// Type the string. `tap` is where the finger lifted, for spatial autocorrect; nil when the
    /// text did not come from a letter tap (accents, space, return, rules).
    case insert(String, tap: CGPoint?)
    /// Delete this many characters (grapheme clusters).
    case deleteBackward(count: Int)
    case deleteWordBackward
    /// Move the cursor by this many UTF-16 units (negative is left), as the space-bar trackpad does.
    case moveCursor(utf16Offset: Int)
    /// Show the key's pop-up. With `alternates` empty it is the plain key preview; otherwise it is
    /// the accent row and `selected` is the highlighted entry, nil when the finger left the row.
    case showPopup(KeyKind, alternates: [String], selected: Int?)
    case hidePopup
    case setPage(Page)
    case setShift(ShiftState)
    /// The keys blank while true: the space bar is acting as a trackpad.
    case trackpad(Bool)
    /// Click and light haptic, at touch-down on a key.
    case feedback
    case showEmoji
    case globe
}

/// Turns finger events into typing effects: which key a touch means, when a pop-up shows, how
/// shift, pages, delete and the space bar behave. It owns the page, the shift state and the
/// touch state, and sees no text (`TypingController` owns the text rules).
///
/// A touch has one role, fixed at touch-down by the key under it, and everything else follows
/// from the role: a character types at touch-up at the key then under the finger, delete acts at
/// touch-down and repeats, the space bar types at touch-up unless a still hold turns it into a
/// trackpad, shift and the page keys resolve at touch-up and can be slid off onto a character.
/// Milestone 6 adds a swipe path to the character role (a touch that travels more than a key
/// pitch before the accent hold fires); everything it needs is already per touch: its start,
/// its current key and the time it entered it.
public struct TypingEngine: Sendable {
    // MARK: - Timings and constants

    /// How long a finger must rest on a letter with accents before the accent row opens. Seconds.
    public static let accentHoldDelay: TimeInterval = 0.36
    /// Where the pop-up row of accents grows from: the finger's x when it opens. Entries are at
    /// least this wide, in points, so a long row stays selectable by a thumb.
    public static let minimumAccentCellWidth: CGFloat = 20
    /// The accent row's width in keycap widths, so a cell is the row's width over its count.
    public static let popupWidthScale: CGFloat = 1.5

    /// Delete repeats this long after touch-down, then every `deleteRepeatInterval`.
    public static let deleteRepeatDelay: TimeInterval = 0.36
    public static let deleteRepeatInterval: TimeInterval = 0.075
    /// From this long after touch-down the repeat is faster.
    public static let deleteFastThreshold: TimeInterval = 0.85
    public static let deleteFastInterval: TimeInterval = 0.05
    /// From this long after touch-down each repeat deletes a whole word.
    public static let deleteWordThreshold: TimeInterval = 1.4
    /// The plan fixes no pace for word deletion; a word per quarter second is quick without
    /// emptying a field in a blink.
    public static let deleteWordInterval: TimeInterval = 0.25

    /// A finger that stays within `trackpadStillRadius` of where it landed on the space bar for
    /// this long turns the bar into a trackpad.
    public static let trackpadHoldDelay: TimeInterval = 0.35
    public static let trackpadStillRadius: CGFloat = 4
    /// Effective travel per cursor step, in points.
    public static let trackpadPointsPerCharacter: CGFloat = 7.5
    /// Shortest time step used for a speed, so two events with the same timestamp do not read as
    /// infinite speed.
    public static let trackpadMinimumInterval: TimeInterval = 0.008
    /// (speed in points per second, gain) pairs, linear between them. Below the first the gain is
    /// 1, above the last it stays at the last.
    public static let trackpadGainCurve: [(speed: CGFloat, gain: CGFloat)] = [
        (100, 1.0), (400, 1.4), (1000, 2.0), (2000, 2.6),
    ]

    /// Two shift taps within this long (touch-down to touch-down) lock caps.
    public static let shiftDoubleTapWindow: TimeInterval = 0.3

    /// A tolerance for comparing times that came from sums of fractions.
    private static let epsilon: TimeInterval = 1e-9
    /// The most delete repeats one event may emit, so a clock that jumps cannot empty a field.
    private static let maximumRepeatsPerEvent = 50

    // MARK: - State

    public private(set) var page: Page
    public private(set) var shift: ShiftState
    /// The frames of the current page, as the view draws them.
    public private(set) var frames: [KeyFrame] = []
    /// How many lifts hit no key and typed the touch's last key instead. Counted for the
    /// keyboard's typing evidence (Setup), never reset by the engine.
    public private(set) var offKeyLifts = 0

    private var metrics: KeyboardMetrics
    private var showsGlobe: Bool
    private var touches: [Int: Touch] = [:]
    /// The touch-down time of the last shift tap that turned shift on, for the double tap.
    private var lastShiftTapDown: TimeInterval?

    public init(
        metrics: KeyboardMetrics, showsGlobe: Bool = false, page: Page = .letters,
        shift: ShiftState = .off
    ) {
        self.metrics = metrics
        self.showsGlobe = showsGlobe
        self.page = page
        self.shift = shift
        recomputeFrames()
    }

    /// New geometry, when the keyboard's width or orientation changes or the globe key appears.
    /// Touches already down keep going; they look keys up again at their next event.
    public mutating func setLayout(metrics: KeyboardMetrics, showsGlobe: Bool) {
        self.metrics = metrics
        self.showsGlobe = showsGlobe
        recomputeFrames()
    }

    /// Moves to a page without an effect: the controller changed it (the emoji panel's ABC key).
    public mutating func setPage(_ page: Page) {
        self.page = page
        recomputeFrames()
    }

    /// Sets shift without an effect. The controller calls this with auto-shift after each change
    /// to the text.
    public mutating func setShift(_ state: ShiftState) {
        shift = state
    }

    /// The width of one cell of the accent row for a key `keyWidth` wide holding `count` entries.
    public static func accentCellWidth(keyWidth: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return minimumAccentCellWidth }
        return max(minimumAccentCellWidth, keyWidth * popupWidthScale / CGFloat(count))
    }

    /// Whether the accent row of `keycap` grows leftward. Keys in the right half of the keyboard
    /// open it toward the middle, as the stock one does, so the row stays on screen; entry 0 is
    /// always the one nearest the key.
    public func accentRowGrowsLeftward(from keycap: CGRect) -> Bool {
        keycap.midX > metrics.width / 2
    }

    /// The trackpad's gain at a finger speed in points per second.
    public static func trackpadGain(speed: CGFloat) -> CGFloat {
        let curve = trackpadGainCurve
        guard let first = curve.first, let last = curve.last else { return 1 }
        if speed <= first.speed { return 1 }
        if speed >= last.speed { return last.gain }
        for index in 1..<curve.count where speed <= curve[index].speed {
            let low = curve[index - 1]
            let high = curve[index]
            let fraction = (speed - low.speed) / (high.speed - low.speed)
            return low.gain + (high.gain - low.gain) * fraction
        }
        return last.gain
    }

    /// The accents of a key, lowercase, nearest first, or empty. iOS English; the table is
    /// unchecked against the stock keyboard until Milestone 2's device pass.
    public static func accents(for key: String) -> [String] {
        accentTable[key] ?? []
    }

    private static let accentTable: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["î", "ï", "í", "ī", "į", "ì"],
        "l": ["ł"],
        "n": ["ñ", "ń"],
        "o": ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"],
        "s": ["ß", "ś", "š"],
        "u": ["û", "ü", "ù", "ú", "ū"],
        "y": ["ÿ"],
        "z": ["ž", "ź", "ż"],
        ".": ["…"],
        "-": ["\u{2013}", "\u{2014}", "•"],
        "$": ["₽", "¥", "€", "¢", "£", "₩"],
        "&": ["§"],
        "?": ["¿"],
        "!": ["¡"],
        "0": ["°"],
        "/": ["\\"],
        "'": ["’", "‘", "‚", "`"],
        "\"": ["”", "“", "„", "«", "»"],
        "%": ["‰"],
    ]

    // MARK: - Touch state

    /// What a touch does, decided by the key it landed on.
    private enum Role: Sendable {
        case character, delete, space, shift, pageKey, button
        /// Already acted on (a rollover committed it); its lift does nothing.
        case finished
    }

    private struct Accents: Sendable {
        var alternates: [String]
        var selected: Int?
        /// The finger's x when the row opened; movement is measured from it.
        var anchorX: CGFloat
        var leftward: Bool
        var cellWidth: CGFloat
    }

    private struct Touch: Sendable {
        var role: Role
        var origin: KeyFrame
        var start: CGPoint
        var point: CGPoint
        var downTime: TimeInterval
        /// The key under the finger now, and since when. The accent hold counts from the entry.
        var currentKey: KeyFrame?
        /// The last key the finger was on. `currentKey` goes nil when the finger leaves every
        /// key (into the strip, past an edge); this does not, so a lift there types this key.
        var lastKey: KeyFrame?
        var keyEnteredAt: TimeInterval
        /// The key whose pop-up this touch is showing, if any.
        var popup: KeyKind?
        var accents: Accents?
        /// Delete: the offset from touch-down of the next repeat.
        var nextRepeat: TimeInterval = TypingEngine.deleteRepeatDelay
        /// Space: the finger left the still radius before the hold, so no trackpad.
        var drifted = false
        var trackpadActive = false
        var trackpadLastX: CGFloat = 0
        var trackpadLastTime: TimeInterval = 0
        var trackpadResidual: CGFloat = 0
        /// Shift: what shift was at touch-down, and whether another finger used it meanwhile.
        var priorShift: ShiftState = .off
        var shiftUsed = false
        /// Page key: the page to return to after a slide onto a key.
        var returnPage: Page = .letters
    }

    private mutating func recomputeFrames() {
        frames = metrics.frames(for: KeyboardLayout.rows(for: page, showsGlobe: showsGlobe))
    }

    // MARK: - Events

    /// Feeds one event and returns what to do. `bias` is the next-letter log-odds the hit tester
    /// uses (Milestone 5.6); pass `[:]` until then.
    public mutating func handle(_ event: TouchEvent, bias: [String: Double]) -> [TypingEffect] {
        var out: [TypingEffect] = []
        switch event {
        case .began(let id, let point, let time):
            began(id: id, point: point, time: time, bias: bias, into: &out)
        case .moved(let id, let point, let time):
            moved(id: id, point: point, time: time, bias: bias, into: &out)
        case .ended(let id, let point, let time):
            ended(id: id, point: point, time: time, bias: bias, into: &out)
        case .cancelled(let id):
            cancelled(id: id, into: &out)
        case .tick(let time):
            for id in touches.keys.sorted() { advance(id: id, to: time, into: &out) }
        }
        return out
    }

    private mutating func began(
        id: Int, point: CGPoint, time: TimeInterval, bias: [String: Double],
        into out: inout [TypingEffect]
    ) {
        guard let frame = HitTester.key(at: point, frames: frames, bias: bias) else { return }

        // Rollover: a character or space still down is committed before this key, so fast typing
        // that overlaps two fingers comes out in order. A held shift counts as used.
        for other in touches.keys.sorted() where other != id {
            guard let held = touches[other] else { continue }
            if held.role == .shift { touches[other]?.shiftUsed = true }
            commitIfHeld(id: other, bias: bias, into: &out)
        }

        out.append(.feedback)
        var touch = Touch(
            role: .button, origin: frame, start: point, point: point, downTime: time,
            currentKey: frame, lastKey: frame, keyEnteredAt: time)

        switch frame.kind {
        case .character:
            touch.role = .character
            touch.popup = frame.kind
            out.append(.showPopup(frame.kind, alternates: [], selected: nil))
        case .delete:
            touch.role = .delete
            out.append(.deleteBackward(count: 1))
        case .space:
            touch.role = .space
        case .shift:
            touch.role = .shift
            touch.priorShift = shift
            // The capitals show while the key is held, as on the stock keyboard.
            if shift == .off {
                shift = .on
                out.append(.setShift(.on))
            }
        case .pageSwitch(let target):
            touch.role = .pageKey
            touch.returnPage = page
            page = target
            recomputeFrames()
            out.append(.setPage(target))
        case .return, .emoji, .globe:
            touch.role = .button
        }
        touches[id] = touch
    }

    private mutating func moved(
        id: Int, point: CGPoint, time: TimeInterval, bias: [String: Double],
        into out: inout [TypingEffect]
    ) {
        guard touches[id] != nil else { return }
        advance(id: id, to: time, into: &out)
        guard var touch = touches[id] else { return }
        touch.point = point

        switch touch.role {
        case .character, .shift, .pageKey:
            if touch.accents != nil {
                updateAccentSelection(&touch, into: &out)
            } else {
                followKey(&touch, bias: bias, time: time, into: &out)
            }
        case .space:
            if touch.trackpadActive {
                moveTrackpad(&touch, to: point, time: time, into: &out)
            } else if distance(point, touch.start) > Self.trackpadStillRadius {
                touch.drifted = true
            }
        case .delete, .button, .finished:
            break
        }
        touches[id] = touch
    }

    private mutating func ended(
        id: Int, point: CGPoint, time: TimeInterval, bias: [String: Double],
        into out: inout [TypingEffect]
    ) {
        guard touches[id] != nil else { return }
        advance(id: id, to: time, into: &out)
        guard var touch = touches.removeValue(forKey: id) else { return }
        touch.point = point

        switch touch.role {
        case .character:
            finishCharacter(touch, bias: bias, into: &out)
        case .space:
            if touch.trackpadActive {
                out.append(.trackpad(false))
            } else {
                typeSpace(into: &out)
            }
        case .delete, .finished:
            break
        case .shift:
            resolveShift(touch, bias: bias, into: &out)
        case .pageKey:
            let landed = HitTester.key(at: point, frames: frames, bias: bias)
            if let landed, case .character(let text) = landed.kind {
                if touch.popup != nil { out.append(.hidePopup) }
                typeCharacter(text, tap: point, into: &out)
                page = touch.returnPage
                recomputeFrames()
                out.append(.setPage(touch.returnPage))
            } else if touch.popup != nil {
                out.append(.hidePopup)
            }
        case .button:
            // A button acts only if the finger is still on it, so sliding off cancels it.
            let landed = HitTester.key(at: point, frames: frames, bias: bias)
            guard landed?.kind == touch.origin.kind else { break }
            switch touch.origin.kind {
            case .return: out.append(.insert("\n", tap: nil))
            case .emoji: out.append(.showEmoji)
            case .globe: out.append(.globe)
            default: break
            }
        }
    }

    private mutating func cancelled(id: Int, into out: inout [TypingEffect]) {
        guard let touch = touches.removeValue(forKey: id) else { return }
        if touch.popup != nil { out.append(.hidePopup) }
        if touch.trackpadActive { out.append(.trackpad(false)) }
        if touch.role == .shift, shift != touch.priorShift {
            shift = touch.priorShift
            out.append(.setShift(shift))
        }
    }

    // MARK: - Timers

    /// Fires whatever has come due for one touch: the accent hold, the trackpad hold, delete
    /// repeats. Called by every event that carries a time, so a lift or a move that arrives after
    /// a hold's deadline sees the hold first.
    private mutating func advance(id: Int, to time: TimeInterval, into out: inout [TypingEffect]) {
        guard var touch = touches[id] else { return }
        switch touch.role {
        case .character:
            if touch.accents == nil, let key = touch.currentKey,
                case .character(let text) = key.kind,
                time - touch.keyEnteredAt + Self.epsilon >= Self.accentHoldDelay
            {
                let base = Self.accents(for: text)
                if !base.isEmpty {
                    let cased = base.map { casedForShift($0) }
                    let accents = Accents(
                        alternates: cased, selected: 0, anchorX: touch.point.x,
                        leftward: accentRowGrowsLeftward(from: key.keycap),
                        cellWidth: Self.accentCellWidth(
                            keyWidth: key.keycap.width, count: cased.count))
                    touch.accents = accents
                    touch.popup = key.kind
                    out.append(.showPopup(key.kind, alternates: cased, selected: 0))
                }
            }
        case .space:
            if !touch.trackpadActive, !touch.drifted,
                time - touch.downTime + Self.epsilon >= Self.trackpadHoldDelay
            {
                touch.trackpadActive = true
                touch.trackpadLastX = touch.point.x
                touch.trackpadLastTime = time
                out.append(.trackpad(true))
            }
        case .delete:
            var emitted = 0
            while time - touch.downTime + Self.epsilon >= touch.nextRepeat,
                emitted < Self.maximumRepeatsPerEvent
            {
                out.append(.feedback)
                out.append(
                    touch.nextRepeat + Self.epsilon >= Self.deleteWordThreshold
                        ? .deleteWordBackward : .deleteBackward(count: 1))
                touch.nextRepeat = Self.repeatOffset(after: touch.nextRepeat)
                emitted += 1
            }
            if emitted == Self.maximumRepeatsPerEvent {
                // The clock jumped; do not owe the repeats it skipped.
                while time - touch.downTime + Self.epsilon >= touch.nextRepeat {
                    touch.nextRepeat = Self.repeatOffset(after: touch.nextRepeat)
                }
            }
        case .shift, .pageKey, .button, .finished:
            break
        }
        touches[id] = touch
    }

    /// The offset of the repeat after the one at `offset`, both measured from touch-down. The pace
    /// steps up at the thresholds, and a repeat is placed on a threshold when the step would cross
    /// it, so the faster pace and the word deletion start exactly there.
    private static func repeatOffset(after offset: TimeInterval) -> TimeInterval {
        let interval: TimeInterval
        if offset + epsilon >= deleteWordThreshold {
            interval = deleteWordInterval
        } else if offset + epsilon >= deleteFastThreshold {
            interval = deleteFastInterval
        } else {
            interval = deleteRepeatInterval
        }
        var next = offset + interval
        for boundary in [deleteFastThreshold, deleteWordThreshold]
        where offset + epsilon < boundary && next > boundary - epsilon {
            next = boundary
            break
        }
        // Round away the error of summing fractions so thresholds compare cleanly.
        return (next * 1e6).rounded() / 1e6
    }

    // MARK: - Characters

    /// Moves the touch to the key now under the finger and keeps the pop-up on it. The accent
    /// hold restarts on each new key.
    private func followKey(
        _ touch: inout Touch, bias: [String: Double], time: TimeInterval,
        into out: inout [TypingEffect]
    ) {
        let key = HitTester.key(at: touch.point, frames: frames, bias: bias)
        guard key?.kind != touch.currentKey?.kind else { return }
        touch.currentKey = key
        if let key { touch.lastKey = key }
        touch.keyEnteredAt = time
        if let key, case .character = key.kind {
            touch.popup = key.kind
            out.append(.showPopup(key.kind, alternates: [], selected: nil))
        } else if touch.popup != nil {
            touch.popup = nil
            out.append(.hidePopup)
        }
    }

    private func updateAccentSelection(_ touch: inout Touch, into out: inout [TypingEffect]) {
        guard var accents = touch.accents, let key = touch.currentKey else { return }
        let selected: Int?
        if touch.point.y > key.hitRect.maxY {
            // Below the key is out of the row: lifting here types nothing.
            selected = nil
        } else {
            let travel = touch.point.x - accents.anchorX
            let step = Int(((accents.leftward ? -travel : travel) / accents.cellWidth).rounded(.down))
            selected = min(max(step, 0), accents.alternates.count - 1)
        }
        guard selected != accents.selected else { return }
        accents.selected = selected
        touch.accents = accents
        out.append(.showPopup(key.kind, alternates: accents.alternates, selected: selected))
    }

    /// The lift of a character touch (or its rollover commit): the accent row's selection, or the
    /// character under the lift point.
    private mutating func finishCharacter(
        _ touch: Touch, bias: [String: Double], into out: inout [TypingEffect]
    ) {
        if touch.popup != nil { out.append(.hidePopup) }
        if let accents = touch.accents {
            if let selected = accents.selected {
                typeCased(accents.alternates[selected], tap: nil, into: &out)
            }
            return
        }
        // A lift that hits no key (the finger drifted into the strip or past an edge) types the
        // key the touch was last on: a character touch that began on a key was meant to type.
        var key = HitTester.key(at: touch.point, frames: frames, bias: bias)
        if key == nil, let last = touch.lastKey {
            key = last
            offKeyLifts += 1
        }
        if let key, case .character(let text) = key.kind {
            typeCharacter(text, tap: touch.point, into: &out)
        }
    }

    /// Commits a held character or space (not a trackpad) as if it had lifted, then marks it
    /// finished so its real lift does nothing.
    private mutating func commitIfHeld(
        id: Int, bias: [String: Double], into out: inout [TypingEffect]
    ) {
        guard var touch = touches[id] else { return }
        switch touch.role {
        case .character:
            finishCharacter(touch, bias: bias, into: &out)
        case .space where !touch.trackpadActive:
            typeSpace(into: &out)
        default:
            return
        }
        touch.role = .finished
        touch.popup = nil
        touch.accents = nil
        touches[id] = touch
    }

    /// Types a key's character in the case shift implies. Shift applies on the letters page only.
    private mutating func typeCharacter(
        _ text: String, tap: CGPoint?, into out: inout [TypingEffect]
    ) {
        typeCased(casedForShift(text), tap: tap, into: &out)
    }

    /// Types text that already has its case. After one capital with shift `on`, shift falls back
    /// to `off`, unless a finger is still holding the shift key (it then restores itself).
    private mutating func typeCased(
        _ text: String, tap: CGPoint?, into out: inout [TypingEffect]
    ) {
        out.append(.insert(text, tap: tap))
        lastShiftTapDown = nil
        if page == .letters, shift == .on, !touches.values.contains(where: { $0.role == .shift }) {
            shift = .off
            out.append(.setShift(.off))
        }
    }

    private mutating func typeSpace(into out: inout [TypingEffect]) {
        out.append(.insert(" ", tap: nil))
        lastShiftTapDown = nil
    }

    private func casedForShift(_ text: String) -> String {
        guard page == .letters, shift != .off else { return text }
        return Self.capitalised(text)
    }

    /// "ß" has no one-letter uppercase in `uppercased()` (it becomes "SS"); the capital sharp s
    /// is the right capital for a key that types one letter.
    private static func capitalised(_ text: String) -> String {
        text == "ß" ? "\u{1E9E}" : text.uppercased()
    }

    // MARK: - Shift

    /// The lift of a shift touch. On the shift key it taps: off to on, on to off (or to caps lock
    /// on a second tap within the window), caps lock to off. Slid onto a character it types that
    /// character as a capital and goes back to what shift was before the touch (caps lock stays,
    /// anything else ends up off). Anywhere else, or if another finger used shift meanwhile, it
    /// restores what it was.
    private mutating func resolveShift(
        _ touch: Touch, bias: [String: Double], into out: inout [TypingEffect]
    ) {
        if touch.popup != nil { out.append(.hidePopup) }
        let landed = HitTester.key(at: touch.point, frames: frames, bias: bias)
        var result = touch.priorShift

        if !touch.shiftUsed {
            if landed?.kind == .shift {
                let isDouble =
                    touch.priorShift == .on
                    && lastShiftTapDown.map {
                        touch.downTime - $0 <= Self.shiftDoubleTapWindow + Self.epsilon
                    } == true
                switch touch.priorShift {
                case .off:
                    result = .on
                    lastShiftTapDown = touch.downTime
                case .on:
                    result = isDouble ? .capsLock : .off
                    lastShiftTapDown = nil
                case .capsLock:
                    result = .off
                    lastShiftTapDown = nil
                }
            } else if let landed, case .character(let text) = landed.kind, page == .letters {
                out.append(.insert(Self.capitalised(text), tap: touch.point))
                lastShiftTapDown = nil
                result = touch.priorShift == .capsLock ? .capsLock : .off
            }
        }
        if shift != result {
            shift = result
            out.append(.setShift(result))
        }
    }

    // MARK: - Trackpad

    /// Turns horizontal travel into cursor steps. Faster movement is amplified, so a long sweep
    /// crosses a line while a slow one places the cursor exactly.
    private func moveTrackpad(
        _ touch: inout Touch, to point: CGPoint, time: TimeInterval,
        into out: inout [TypingEffect]
    ) {
        let travel = point.x - touch.trackpadLastX
        let elapsed = max(time - touch.trackpadLastTime, Self.trackpadMinimumInterval)
        let speed = abs(travel) / CGFloat(elapsed)
        touch.trackpadLastX = point.x
        touch.trackpadLastTime = time
        touch.trackpadResidual += travel * Self.trackpadGain(speed: speed)
        let steps = Int((touch.trackpadResidual / Self.trackpadPointsPerCharacter).rounded(.towardZero))
        guard steps != 0 else { return }
        touch.trackpadResidual -= CGFloat(steps) * Self.trackpadPointsPerCharacter
        out.append(.moveCursor(utf16Offset: steps))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}
