import MurmurDesign
import MurmurKit
import MurmurTyping
import Observation
import OSLog
import UIKit

extension MetricsConstants {
    /// The stock keyboard's measurements for one orientation, filled from the design tokens.
    /// `MurmurTyping` cannot import `MurmurDesign`, so the iPhone target does it here.
    static func keyboard(isLandscape: Bool) -> MetricsConstants {
        MetricsConstants(
            stripHeight: isLandscape ? DS.Keyboard.stripHeightLandscape : DS.Keyboard.stripHeight,
            stripGap: isLandscape ? DS.Keyboard.stripGapLandscape : DS.Keyboard.stripGap,
            keycapHeight: isLandscape ? DS.Keyboard.keycapHeightLandscape : DS.Keyboard.keycapHeight,
            rowGap: isLandscape ? DS.Keyboard.rowGapLandscape : DS.Keyboard.rowGap,
            keyGap: DS.Keyboard.keySpacing,
            sideInset: DS.Keyboard.sideInset,
            bottomInset: DS.Keyboard.bottomInset,
            referenceWidth: DS.Keyboard.referenceWidth,
            modifierKeyWidth: DS.Keyboard.functionKeyWidth,
            pageKeyWidth: DS.Keyboard.pageKeyWidth,
            emojiKeyWidth: DS.Keyboard.pageKeyWidth,
            globeKeyWidth: DS.Keyboard.pageKeyWidth,
            returnKeyWidth: DS.Keyboard.returnKeyWidth,
            spaceHitReach: DS.Keyboard.spaceHitReach)
    }
}

/// What the keys did since the keyboard last appeared, written to `KeyboardStatus` so a device
/// run says whether typed letters are lost and where. Times are in milliseconds.
struct TypingStats: Equatable {
    /// Touch-downs on any key.
    var touchDowns = 0
    /// Insert effects the keys produced: the characters, spaces and returns that reached the field.
    var typed = 0
    /// Touches iOS cancelled (a system gesture, the keyboard going away). A cancelled character
    /// touch types nothing.
    var cancelled = 0
    /// Lifts that hit no key and typed the touch's last key instead (`TypingEngine.offKeyLifts`).
    var offKey = 0
    /// The longest `handle`: the event in to its effects applied.
    var slowestHandleMs = 0.0
    /// The largest gap between a touch's timestamp and the keyboard handling it. A burst of
    /// touches delivered late, or the main thread busy, shows here.
    var maxDeliveryMs = 0.0
    /// The slowest autocorrect evaluation (parse, decode and policy, at a word end or for the
    /// strip's correction), run on the main actor. Zero until one ran.
    var slowestAutocorrectMs = 0.0
}

/// The typing side of the keyboard: it owns `TypingEngine`, applies what the engine decides to
/// the host field, and keeps the strip's suggestions.
///
/// The path of a touch: `KeyPlaneView` forwards each finger event here (`handle`), the engine
/// returns effects, and `apply` turns them into calls on `textDocumentProxy` or on the plane.
/// The engine never sees the text, so the rules that need it live here: auto-shift, smart
/// quotes and dashes, the double-space period, a lone "i" becoming "I", and the space a tapped
/// suggestion types (`PendingSpace`). After every change to the text the controller re-reads
/// `documentContextBeforeInput`, so the shift key and the suggestions follow the text whoever
/// changed it (the keys, dictation, the history panel, or the host).
@MainActor
@Observable
final class TypingController {
    /// The strip's cells, left to right. Empty when the field offers none.
    private(set) var suggestions: [Suggestion] = []

    /// The strip's height at the current orientation. The strip is SwiftUI and reads it.
    private(set) var stripHeight = DS.Keyboard.stripHeight

    /// The word autocorrect replaced, while its undo offer shows: the strip's left suggestion
    /// cell is the undo chip with this word. Nil when no offer is live.
    private(set) var undoChip: String?

    /// What a tap on the key plane's emoji key does. Set by the keyboard view, which owns the
    /// panels.
    @ObservationIgnored var onShowEmoji: () -> Void = {}
    /// The globe key's touches, with their event, for the keyboard list. Set by the controller.
    @ObservationIgnored var onGlobe: (UIView, UIEvent) -> Void = { _, _ in }
    /// Pop-ups draw on this view's layer, so a first-row pop-up can rise over the strip.
    @ObservationIgnored weak var popupHost: UIView?

    @ObservationIgnored private var engine: TypingEngine
    @ObservationIgnored private let proxy: () -> UITextDocumentProxy?
    @ObservationIgnored private weak var plane: KeyPlaneView?
    @ObservationIgnored private var metrics: KeyboardMetrics
    @ObservationIgnored private var showsGlobe = false
    @ObservationIgnored private var traits = FieldTraits.standard
    @ObservationIgnored private var returnIsProminent = false
    @ObservationIgnored private var documentID: UUID?
    @ObservationIgnored private var model: TypingModel?
    @ObservationIgnored private var modelLoaded = false
    @ObservationIgnored private var pending = PendingSpace()
    @ObservationIgnored private var lastSpaceTime: TimeInterval?
    /// Shift is on because the text asked for a capital (not because the key was tapped), so
    /// the text changing again may turn it off. A tapped shift is never taken back.
    @ObservationIgnored private var autoShifted = false
    /// The plane needs a new `KeyPlaneState`: the page, shift or return key changed.
    @ObservationIgnored private var stateIsDirty = false
    /// The text changed (by the keys, dictation or the host) and shift and the strip have not
    /// caught up. They do in one deferred pass per run-loop turn (`scheduleTextRefresh`), so a
    /// burst of touches is typed before any strip work, and a host that reports each change
    /// after the keys already did costs one pass and not two.
    @ObservationIgnored private var textRefreshPending = false
    @ObservationIgnored private var textRefreshScheduled = false
    /// The host reported a change, so the field's identity and traits are read again too.
    @ObservationIgnored private var fieldCheckPending = false
    @ObservationIgnored private var counters = TypingStats()
    @ObservationIgnored private var offKeyAtReset = 0

    // Autocorrect (Milestone 5). The logic lives in `MurmurTyping`; this is the state it needs.
    /// The decoder, the policy and the owner's words. Nil until the word model has loaded.
    @ObservationIgnored private var autocorrector: Autocorrector?
    /// The taps of the word being typed. Emptied on a space or mark, a cursor move, anything typed
    /// by something other than a letter key, and whenever the field's word is not what was typed.
    @ObservationIgnored private var tracker = WordTapTracker()
    /// The replacement the owner may take back, from the autocorrect until the next edit. The
    /// strip shows the chip once the first delete has removed the space.
    @ObservationIgnored private var undo: UndoOffer? {
        didSet {
            let chip = undo?.isShown == true ? undo?.original : nil
            if chip != undoChip { undoChip = chip }
        }
    }
    /// The letters page's frames in the engine's coordinates, whatever page shows: the decoder
    /// measures every tap against these.
    @ObservationIgnored private var lettersFrames: [KeyFrame] = []
    @ObservationIgnored private var lettersLayout: LettersLayout?
    /// The next-letter bias, built off the typing path and cached per prefix.
    @ObservationIgnored private var biasCache = NextLetterBiasCache()
    @ObservationIgnored private var biasTask: Task<Void, Never>?
    /// The Murmur dictionary revision the lexicon was built from, and the words the system's
    /// supplementary lexicon (contacts, text replacements) brought.
    @ObservationIgnored private var lexiconRevision = -1
    @ObservationIgnored private var systemWords: [String] = []

    /// Most system words kept: the decoder visits every lexicon entry, so a large one would cost
    /// each decode.
    @ObservationIgnored private static let systemWordLimit = 1000

    /// What the letters page's frames were built for.
    private struct LettersLayout: Equatable {
        var width: CGFloat
        var isLandscape: Bool
        var showsGlobe: Bool
    }

    @ObservationIgnored private static let log = Logger(subsystem: "ai.pivotstudio.murmur", category: "keyboard")

    init(proxy: @escaping () -> UITextDocumentProxy?) {
        self.proxy = proxy
        // Portrait at the reference width until the first layout says otherwise.
        let initial = KeyboardMetrics(
            width: DS.Keyboard.referenceWidth, isLandscape: false,
            constants: .keyboard(isLandscape: false))
        metrics = initial
        engine = TypingEngine(metrics: initial)
        lettersFrames = initial.frames(for: KeyboardLayout.rows(for: .letters, showsGlobe: false))
    }

    // MARK: - Geometry

    /// The height of the whole keyboard (strip and keys) at the current width and orientation.
    var keyboardHeight: CGFloat { metrics.height }

    /// The portrait height, which does not depend on the width. The height constraint starts
    /// here, before the first layout knows the orientation.
    static var initialHeight: CGFloat {
        KeyboardMetrics(
            width: DS.Keyboard.referenceWidth, isLandscape: false,
            constants: .keyboard(isLandscape: false)
        ).height
    }

    /// Called at each layout. The strip and the keys change size with the width, and the globe
    /// key appears or goes with the user's keyboard list.
    func setLayout(width: CGFloat, isLandscape: Bool, showsGlobe: Bool) {
        guard width > 0 else { return }
        let next = KeyboardMetrics(
            width: width, isLandscape: isLandscape, constants: .keyboard(isLandscape: isLandscape))
        let framesBefore = engine.frames
        metrics = next
        self.showsGlobe = showsGlobe
        engine.setLayout(metrics: next, showsGlobe: showsGlobe)
        if engine.frames != framesBefore { stateIsDirty = true }
        updateLettersFrames(width: width, isLandscape: isLandscape, showsGlobe: showsGlobe)
        if stripHeight != next.constants.stripHeight {
            stripHeight = next.constants.stripHeight
            stateIsDirty = true
        }
        flushState()
    }

    /// The decoder reads the letters page whatever page the keys show, so its frames are kept
    /// apart from the engine's and rebuilt only when the geometry changed.
    private func updateLettersFrames(width: CGFloat, isLandscape: Bool, showsGlobe: Bool) {
        let layout = LettersLayout(width: width, isLandscape: isLandscape, showsGlobe: showsGlobe)
        guard layout != lettersLayout else { return }
        lettersLayout = layout
        lettersFrames = metrics.frames(for: KeyboardLayout.rows(for: .letters, showsGlobe: showsGlobe))
        autocorrector?.setLettersFrames(lettersFrames)
    }

    /// The height of the key plane: everything under the strip.
    var planeHeight: CGFloat { metrics.height - metrics.constants.stripHeight }

    // MARK: - The plane

    /// The plane the view controller owns: a direct subview of the keyboard's root view, not
    /// part of the SwiftUI hierarchy. This points at it and gives it the current state.
    func attach(_ plane: KeyPlaneView) {
        self.plane = plane
        plane.popupHost = popupHost
        plane.onGlobe = onGlobe
        plane.onTouch = { [weak self] event in self?.handle(event) }
        plane.state = currentState
    }

    func detach(_ plane: KeyPlaneView) {
        plane.onTouch = nil
        if self.plane === plane { self.plane = nil }
    }

    /// The emoji and history panels replace the keys: the plane hides while one shows, so it
    /// takes no touches, and a touch it still holds ends first.
    func setPlaneVisible(_ visible: Bool) {
        guard let plane, plane.isHidden == visible else { return }
        if !visible { plane.cancelAllTouches() }
        plane.isHidden = !visible
    }

    private var currentState: KeyPlaneState {
        KeyPlaneState(
            frames: engine.frames, page: engine.page, shift: engine.shift,
            returnTitle: traits.returnKeyTitle, returnProminent: returnIsProminent,
            stripHeight: metrics.constants.stripHeight)
    }

    private func flushState() {
        guard stateIsDirty else { return }
        stateIsDirty = false
        plane?.state = currentState
    }

    // MARK: - Appearance and field changes

    /// The keyboard came up: read the field, start on the right page, and reset what belongs to
    /// the last field (a pending space, the double-space clock).
    func keyboardAppeared() {
        counters = TypingStats()
        offKeyAtReset = engine.offKeyLifts
        if !modelLoaded {
            modelLoaded = true
            do {
                let loaded = try TypingModel.bundled()
                model = loaded
                autocorrector = Autocorrector(model: loaded, lettersFrames: lettersFrames)
                buildBias(model: loaded)
            } catch {
                Self.log.error("word model did not load: \(String(describing: error), privacy: .public)")
            }
        }
        refreshLexicon(force: true)
        readTraits()
        resetFieldState()
        engine.setPage(traits.keyboardKind == .number ? .numbers : .letters)
        engine.setShift(.off)
        stateIsDirty = true
        refreshText()
        flushState()
    }

    /// The counters since the keyboard last appeared; the engine owns the off-key count.
    var stats: TypingStats {
        var snapshot = counters
        snapshot.offKey = engine.offKeyLifts - offKeyAtReset
        return snapshot
    }

    /// The keyboard went away: log what the keys did, so a device run reads it from the log as
    /// well as from Setup.
    func keyboardDisappeared() {
        let snapshot = stats
        Self.log.info(
            "typing: \(snapshot.touchDowns) touch-downs, \(snapshot.typed) typed, \(snapshot.cancelled) cancelled, \(snapshot.offKey) off-key, slowest handle \(snapshot.slowestHandleMs, format: .fixed(precision: 1)) ms, delivery \(snapshot.maxDeliveryMs, format: .fixed(precision: 1)) ms, autocorrect \(snapshot.slowestAutocorrectMs, format: .fixed(precision: 1)) ms")
        undo = nil
        tracker.reset()
    }

    /// The host changed the text, the selection or the field. Traits can differ between fields,
    /// so they are read again; the shift key and the strip follow the text, in the deferred
    /// pass.
    func textDidChange() {
        fieldCheckPending = true
        scheduleTextRefresh()
    }

    /// The keyboard is on screen. The field's traits can still be those of the last field when
    /// `keyboardAppeared` runs (`viewWillAppear`), so one deferred pass re-reads them, the
    /// field's identity, shift and the strip, whether or not the host reports a change.
    func keyboardDidAppear() {
        fieldCheckPending = true
        scheduleTextRefresh()
    }

    /// The emoji panel's ABC key: back to the letters page.
    func showLetters() {
        engine.setPage(.letters)
        stateIsDirty = true
        flushState()
    }

    private func resetFieldState() {
        documentID = proxy()?.documentIdentifier
        pending.disarm()
        lastSpaceTime = nil
        autoShifted = false
        // Taps and an undo offer belong to the text of the last field.
        tracker.reset()
        undo = nil
    }

    /// Maps the proxy's traits onto `FieldTraits`. Each optional-looking property is read into
    /// an explicitly optional constant, because the protocol declares them optional and an
    /// unset one means the default.
    private func readTraits() {
        guard let proxy = proxy() else { return }
        let autocorrection: UITextAutocorrectionType? = proxy.autocorrectionType
        let spelling: UITextSpellCheckingType? = proxy.spellCheckingType
        let secure: Bool? = proxy.isSecureTextEntry
        let keyboard: UIKeyboardType? = proxy.keyboardType
        let capitalisation: UITextAutocapitalizationType? = proxy.autocapitalizationType
        let quotes: UITextSmartQuotesType? = proxy.smartQuotesType
        let dashes: UITextSmartDashesType? = proxy.smartDashesType
        let returnKey: UIReturnKeyType? = proxy.returnKeyType

        let next = FieldTraits(
            autocorrectionAllowed: autocorrection != .no,
            spellCheckingAllowed: spelling != .no,
            isSecure: secure ?? false,
            keyboardKind: Self.kind(of: keyboard),
            autocapitalization: Self.mode(of: capitalisation),
            smartQuotes: quotes != .no,
            smartDashes: dashes != .no,
            returnKeyTitle: Self.title(for: returnKey))
        let prominent = Self.isProminent(returnKey)
        if next != traits || prominent != returnIsProminent {
            traits = next
            returnIsProminent = prominent
            stateIsDirty = true
        }
    }

    private static func kind(of type: UIKeyboardType?) -> FieldKeyboardKind {
        switch type {
        case .URL?: .url
        case .emailAddress?: .email
        case .numberPad?, .decimalPad?, .asciiCapableNumberPad?: .number
        case .phonePad?, .namePhonePad?: .phone
        case .webSearch?: .webSearch
        default: .default
        }
    }

    private static func mode(of type: UITextAutocapitalizationType?) -> AutocapMode {
        switch type {
        case .none?: .none
        case .words?: .words
        case .allCharacters?: .allCharacters
        default: .sentences
        }
    }

    /// The word for a return key with a job; nil for a plain new line, which shows the glyph.
    private static func title(for type: UIReturnKeyType?) -> String? {
        switch type {
        case .send?: "send"
        case .search?, .google?, .yahoo?: "search"
        case .go?, .route?: "go"
        case .done?: "done"
        case .next?: "next"
        case .join?: "join"
        default: nil
        }
    }

    /// Apple's keyboard turns return blue when the field gives it a job other than a new line.
    private static func isProminent(_ type: UIReturnKeyType?) -> Bool {
        switch type {
        case nil, .default?, .continue?: false
        default: true
        }
    }

    // MARK: - Events

    /// One finger event, from the plane. Counts it, and times it from entry to its effects
    /// applied; the delivery delay is how long the event waited, by the touch's own timestamp
    /// (`systemUptime`, as `ProcessInfo` reads it), before the keyboard got to it.
    func handle(_ event: TouchEvent) {
        let entered = ContinuousClock.now
        let uptime = ProcessInfo.processInfo.systemUptime
        switch event {
        case .began(_, _, let time):
            counters.touchDowns += 1
            noteDelivery(uptime - time)
        case .moved(_, _, let time), .ended(_, _, let time):
            noteDelivery(uptime - time)
        case .cancelled:
            counters.cancelled += 1
        case .tick:
            break
        }
        let effects = engine.handle(event, bias: biasForTouch())
        if !effects.isEmpty { apply(effects) }
        let elapsed = (ContinuousClock.now - entered).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        counters.slowestHandleMs = max(counters.slowestHandleMs, milliseconds)
    }

    private func noteDelivery(_ seconds: TimeInterval) {
        counters.maxDeliveryMs = max(counters.maxDeliveryMs, seconds * 1000)
    }

    /// Applies the engine's effects in order. Typing effects go through the text rules; the rest
    /// are calls on the plane. Once the batch is done, a change to the text re-evaluates shift
    /// and the suggestions, and a changed page or shift goes to the plane.
    private func apply(_ effects: [TypingEffect]) {
        var textChanged = false
        for effect in effects {
            switch effect {
            case .insert(let text, let tap):
                typeInsert(text, tap: tap)
                counters.typed += 1
                textChanged = true
            case .deleteBackward(let count):
                // The one delete that follows a replacement keeps its offer (and shows it);
                // anything else ends it. The taps of the word lose the letters deleted.
                undo = undo?.afterDelete(count: count)
                tracker.dropLast(count)
                deleteBackward(count)
                textChanged = true
            case .deleteWordBackward:
                undo = nil
                tracker.reset()
                deleteWordBackward()
                textChanged = true
            case .moveCursor(let offset):
                undo = nil
                tracker.reset()
                proxy()?.adjustTextPosition(byCharacterOffset: offset)
                textChanged = true
            case .showPopup(let kind, let alternates, let selected):
                showPopup(kind, alternates: alternates, selected: selected)
            case .hidePopup:
                plane?.hidePopup()
            case .setPage:
                // A page key at touch-down. The engine has switched; the keys follow.
                stateIsDirty = true
            case .setShift:
                // The user's own shift (or the one after a capital): not the text's doing.
                autoShifted = false
                stateIsDirty = true
            case .trackpad(let active):
                plane?.setTrackpad(active)
            case .feedback:
                KeyFeedback.press()
            case .showEmoji:
                onShowEmoji()
            case .globe:
                // The globe is a button over its key, which takes its touches itself.
                break
            }
        }
        if textChanged { textChangedByKeys() }
        flushState()
    }

    private func showPopup(_ kind: KeyKind, alternates: [String], selected: Int?) {
        guard let plane, let keycap = engine.frames.first(where: { $0.kind == kind })?.keycap else { return }
        plane.showPopup(
            kind, alternates: alternates, selected: selected,
            growsLeftward: engine.accentRowGrowsLeftward(from: keycap),
            cellWidth: TypingEngine.accentCellWidth(keyWidth: keycap.width, count: alternates.count))
    }

    // MARK: - Typing

    /// Rules that read the text and change letters apply in ordinary prose fields.
    private var textRulesApply: Bool {
        traits.autocorrectionAllowed && isProseField
    }

    /// Not a password, an address, a number or a phone field.
    private var isProseField: Bool {
        guard !traits.isSecure else { return false }
        return traits.keyboardKind == .default || traits.keyboardKind == .webSearch
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// How much of the text before the cursor the strip and autocorrect read.
    private static let contextLimit = 400

    /// One typed string. A single character goes through the rules; anything longer (an accent
    /// the engine already cased, a double-space replacement) goes in as it is. `tap` is where a
    /// letter key lifted: the word's taps, for autocorrect. Any key but a delete ends an undo
    /// offer; the autocorrect this key may cause starts a new one.
    private func typeInsert(_ text: String, tap: CGPoint?) {
        undo = nil
        guard let proxy = proxy() else { return }
        guard text.count == 1, let mark = text.first else {
            pending.disarm()
            lastSpaceTime = nil
            tracker.reset()
            proxy.insertText(text)
            return
        }
        var before = proxy.documentContextBeforeInput ?? ""

        if mark == " " {
            typeSpace(before: before, proxy: proxy)
            return
        }

        // A mark that closes a word takes the space a tapped suggestion typed.
        if pending.takesSpace(before: mark), before.last == " " {
            proxy.deleteBackward()
            before.removeLast()
        }
        pending.disarm()
        lastSpaceTime = nil

        // A closing mark ends the word, so the word is checked before the mark goes in.
        if PendingSpace.closingMarks.contains(mark) {
            before = finishWord(before: before, terminator: String(mark))
        }

        if textRulesApply, let fix = TextRules.standaloneI(before: before, typed: mark) {
            perform(fix)
            before = String(before.dropLast()) + "I"
        }

        switch mark {
        case "'", "\"":
            tracker.reset()
            proxy.insertText(TextRules.smartQuote(mark, before: before, enabled: traits.smartQuotes && isProseField))
        case "-":
            tracker.reset()
            if let dash = TextRules.smartDash(before: before, enabled: traits.smartDashes && isProseField) {
                perform(dash)
            } else {
                proxy.insertText("-")
            }
        default:
            proxy.insertText(String(mark))
            // A letter key's lift is one more tap of the word; everything else ends the word.
            if mark.isLetter, let tap {
                tracker.append(letter: String(mark), at: tap)
            } else {
                tracker.reset()
            }
        }
    }

    private func typeSpace(before: String, proxy: UITextDocumentProxy) {
        var before = before
        let time = now
        if pending.consumeSpace(), before.last == " " {
            // The suggestion already typed this space. The press still counts toward the
            // double space, so two quick presses after a suggestion give a period.
            lastSpaceTime = time
            return
        }
        if isProseField,
            let period = TextRules.doubleSpacePeriod(before: before, lastSpaceTime: lastSpaceTime, now: time)
        {
            perform(period)
            lastSpaceTime = nil
            return
        }
        before = finishWord(before: before, terminator: " ")
        if textRulesApply, let fix = TextRules.standaloneI(before: before, typed: " ") {
            perform(fix)
        }
        proxy.insertText(" ")
        lastSpaceTime = time
    }

    // MARK: - Autocorrect

    /// A space or closing mark is about to be typed: the word before the cursor ends. Decodes its
    /// taps, asks the policy, and on a replacement deletes the word and types the fix in its
    /// place (smart quotes turn the contraction's apostrophe curly). The offer to take it back
    /// starts here. Without taps (the word was typed before the keyboard appeared, or the host
    /// changed it) the contraction rule still applies. Returns the text before the cursor as it
    /// now stands, and always empties the taps: they belong to the word that just ended.
    private func finishWord(before: String, terminator: String) -> String {
        defer { tracker.reset() }
        guard textRulesApply, autocorrector != nil, let proxy = proxy() else { return before }
        // A word cut in two by the cursor is not the word the taps describe.
        if proxy.documentContextAfterInput?.first?.isLetter == true { return before }
        refreshLexicon()
        let started = ContinuousClock.now
        let result = autocorrector?.evaluate(
            textBefore: String(before.suffix(Self.contextLimit)), tracker: tracker, field: traits)
        noteAutocorrectTime(since: started)
        guard let result, let replacement = result.replacement else { return before }

        let typed = smartApostrophes(replacement.text)
        for _ in 0..<result.word.text.count { proxy.deleteBackward() }
        proxy.insertText(typed)
        undo = UndoOffer(original: result.word.text, replacement: typed, terminator: terminator)
        return result.word.textBeforeWord + typed
    }

    /// The model stores a straight apostrophe; with smart quotes on the field gets the curly one.
    private func smartApostrophes(_ text: String) -> String {
        traits.smartQuotes ? text.replacingOccurrences(of: "'", with: "\u{2019}") : text
    }

    /// The strip's leading chip: puts the original word back in place of the replacement, with
    /// no space, and refuses that fix for the session (`RejectionSet.recordUndo`).
    func chooseUndo() {
        guard let offer = undo, let proxy = proxy() else { return }
        KeyFeedback.press()
        let before = proxy.documentContextBeforeInput ?? ""
        if offer.isConsistent(with: before) {
            for _ in 0..<offer.restoreDeleteCount { proxy.deleteBackward() }
            proxy.insertText(offer.original)
            autocorrector?.recordUndo(offer)
        }
        undo = nil
        tracker.reset()
        pending.disarm()
        lastSpaceTime = nil
        textChangedByKeys()
        flushState()
    }

    private func noteAutocorrectTime(since started: ContinuousClock.Instant) {
        let elapsed = (ContinuousClock.now - started).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        counters.slowestAutocorrectMs = max(counters.slowestAutocorrectMs, milliseconds)
    }

    /// Rebuilds the owner's lexicon when the Murmur dictionary changed (its revision moved) or
    /// the system's words arrived. The dictionary is reloaded by `KeyboardDictation` right after
    /// this controller's `keyboardAppeared`, so the revision is checked again at each word end.
    private func refreshLexicon(force: Bool = false) {
        let store = DictionaryStore.shared
        guard force || store.revision != lexiconRevision else { return }
        lexiconRevision = store.revision
        autocorrector?.lexicon = UserLexicon(entries: store.entries, systemWords: systemWords)
    }

    /// The system's supplementary lexicon (`requestSupplementaryLexicon`: contact names and text
    /// replacements) arrived: its `documentText`s protect those words and pull near misses.
    func setSystemLexicon(_ words: [String]) {
        var seen = Set<String>()
        systemWords = words.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(Self.systemWordLimit).map { $0 }
        refreshLexicon(force: true)
    }

    // MARK: - Next-letter bias

    /// Builds the bias tables once, on a background task: one pass over the model's unigram
    /// column, which is too long for the typing path. The cache serves no bias until it lands.
    private func buildBias(model: TypingModel) {
        guard biasTask == nil else { return }
        biasTask = Task.detached(priority: .utility) { [weak self] in
            let bias = NextLetterBias(model: model)
            await self?.installBias(bias)
        }
    }

    private func installBias(_ bias: NextLetterBias) {
        biasCache.install(bias)
    }

    /// The log-odds for this touch, only in fields that take autocorrect and on the letters page.
    private func biasForTouch() -> [String: Double] {
        guard engine.page == .letters, AutocorrectPolicy.allows(traits) else { return [:] }
        return biasCache.logOdds(tracker: tracker)
    }

    /// Effects a text rule asked for: the rules speak in the engine's vocabulary, and only these
    /// three ever appear in what they return.
    private func perform(_ effects: [TypingEffect]) {
        for effect in effects {
            switch effect {
            case .deleteBackward(let count):
                for _ in 0..<count { proxy()?.deleteBackward() }
            case .insert(let text, _):
                proxy()?.insertText(text)
            case .setShift(let state):
                engine.setShift(state)
                autoShifted = state == .on
                stateIsDirty = true
            default:
                break
            }
        }
    }

    private func deleteBackward(_ count: Int) {
        pending.disarm()
        lastSpaceTime = nil
        for _ in 0..<count { proxy()?.deleteBackward() }
    }

    /// Deletes back to the start of the previous word: the spaces before the cursor, then the
    /// word or the one mark before them. A line break is its own step.
    private func deleteWordBackward() {
        guard let proxy = proxy() else { return }
        pending.disarm()
        lastSpaceTime = nil
        let before = Array((proxy.documentContextBeforeInput ?? "").suffix(120))
        guard var index = before.indices.last else {
            proxy.deleteBackward()
            return
        }
        var count = 0
        if before[index].isNewline {
            proxy.deleteBackward()
            return
        }
        while index >= 0, before[index].isWhitespace, !before[index].isNewline {
            count += 1
            index -= 1
        }
        if index >= 0 {
            if Self.isWordCharacter(before[index]) {
                while index >= 0, Self.isWordCharacter(before[index]) {
                    count += 1
                    index -= 1
                }
            } else if !before[index].isNewline {
                count += 1
            }
        }
        for _ in 0..<max(count, 1) { proxy.deleteBackward() }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "’"
    }

    // MARK: - Text from elsewhere

    /// Text typed by something other than the keys (the emoji panel, the history panel). It
    /// ends a pending suggestion space like any other key.
    func insertExternal(_ text: String) {
        pending.disarm()
        lastSpaceTime = nil
        undo = nil
        tracker.reset()
        proxy()?.insertText(text)
        textChangedByKeys()
        flushState()
    }

    func deleteExternal() {
        undo = nil
        tracker.reset()
        deleteBackward(1)
        textChangedByKeys()
        flushState()
    }

    /// Dictation typed into the field on its own. Shift and the strip catch up.
    func noteDictationInserted() {
        pending.disarm()
        lastSpaceTime = nil
        undo = nil
        tracker.reset()
        textChangedByKeys()
        flushState()
    }

    /// Dictation asks, as it types, whether the first letter is to be capital: the shift key's
    /// state. A one-shot shift is spent by it, as a typed capital spends it; caps lock stays.
    func takeShiftForDictation() -> Bool {
        let wasOn = engine.shift != .off
        if engine.shift == .on {
            engine.setShift(.off)
            autoShifted = false
            stateIsDirty = true
            flushState()
        }
        return wasOn
    }

    // MARK: - Shift

    private func textChangedByKeys() {
        scheduleTextRefresh()
    }

    /// Asks for one pass over shift and the strip at the end of this run-loop turn. Any number
    /// of requests before it runs make one pass: each key used to read the field's text twice
    /// and publish to SwiftUI before the next touch was handled.
    private func scheduleTextRefresh() {
        textRefreshPending = true
        guard !textRefreshScheduled else { return }
        textRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.runTextRefresh()
        }
    }

    private func runTextRefresh() {
        textRefreshScheduled = false
        guard textRefreshPending else { return }
        textRefreshPending = false
        if fieldCheckPending {
            fieldCheckPending = false
            let id = proxy()?.documentIdentifier
            if id != documentID { resetFieldState() }
        }
        // The traits are read on every pass, not only after the host reported a change. At
        // `viewWillAppear` the proxy can still hold the previous field's (or no) traits, and
        // `autocapitalizationType` then reads `.none`; a fresh Notes note stayed lowercase on a
        // device because nothing read it again. The reads are cheap, and a changed value marks
        // the plane dirty, so the shift key follows in this same pass.
        readTraits()
        refreshText()
        flushState()
    }

    /// Reads the field's text once and brings shift and the strip in step with it. Auto-shift is
    /// recomputed on every call, including for an empty field where nothing has been typed: the
    /// first capital of a new note depends on the traits alone.
    private func refreshText() {
        guard let proxy = proxy() else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput
        // The host (or anything else) may have changed the text behind our edits: taps and an
        // undo offer survive only while the field still reads the way we left it.
        if !tracker.isEmpty, !tracker.isConsistent(with: before) { tracker.reset() }
        if let offer = undo, !offer.isConsistent(with: before) { undo = nil }
        recomputeAutoShift(before: before)
        if let model {
            biasCache.noteText(
                before: String(before.suffix(Self.contextLimit)),
                followedByLetter: after?.first?.isLetter == true, model: model)
        }
        refreshSuggestions(before: before, after: after)
    }

    /// Turns shift on when the text asks for a capital next, and takes back only a shift that
    /// the text itself turned on. A tapped shift stays; caps lock is never touched.
    private func recomputeAutoShift(before: String) {
        let wants = TextRules.autoShift(before: before, autocapitalization: traits.autocapitalization)
        switch engine.shift {
        case .capsLock:
            break
        case .off:
            if wants {
                engine.setShift(.on)
                autoShifted = true
                stateIsDirty = true
            }
        case .on:
            if !wants, autoShifted {
                engine.setShift(.off)
                autoShifted = false
                stateIsDirty = true
            }
        }
    }

    // MARK: - Suggestions

    /// Suggestions help in prose fields that accept autocorrection. A word cut in the middle
    /// (letters right after the cursor) has nothing to complete.
    private var suggestionsAllowed: Bool {
        traits.autocorrectionAllowed && isProseField
    }

    /// The strip's cells for the text before the cursor. Assigned only when they differ, so
    /// SwiftUI does not render the strip for a keystroke that changed nothing in it.
    private func refreshSuggestions(before: String, after: String?) {
        var next: [Suggestion] = []
        if suggestionsAllowed, let model, after?.first?.isLetter != true {
            let tail = String(before.suffix(Self.contextLimit))
            next = SuggestionEngine.suggestions(before: tail, model: model)
            // Mid-word, a confident correction takes the centre cell, the typed word stays on
            // the left in quotes, and one completion stays on the right. The evaluation is the
            // one the word's end will make, run once per coalesced refresh.
            if next.first?.kind == .typed {
                refreshLexicon()
                let started = ContinuousClock.now
                let fix = autocorrector?.evaluate(textBefore: tail, tracker: tracker, field: traits)?.stripCorrection
                noteAutocorrectTime(since: started)
                if let fix { next = SuggestionEngine.merging(correction: fix, into: next) }
            }
        }
        if next != suggestions { suggestions = next }
    }

    /// A tap on a strip cell: the typed word is replaced by the suggestion and a space is typed
    /// after it, which `PendingSpace` then lets the next space press, or a closing mark, take.
    /// The model stores a straight apostrophe, so smart quotes turn it curly here.
    func choose(_ suggestion: Suggestion) {
        guard let proxy = proxy() else { return }
        KeyFeedback.press()
        undo = nil
        tracker.reset()
        let before = proxy.documentContextBeforeInput ?? ""
        if suggestion.kind == .typed, textRulesApply,
            let fix = TextRules.standaloneI(before: before, typed: " ")
        {
            perform(fix)
        }
        let edit = SuggestionEngine.edit(applying: suggestion, before: before)
        for _ in 0..<edit.deleteCount { proxy.deleteBackward() }
        let text = traits.smartQuotes ? edit.insert.replacingOccurrences(of: "'", with: "’") : edit.insert
        proxy.insertText(text)
        pending.noteSuggestionInserted(at: now)
        lastSpaceTime = nil
        textChangedByKeys()
        flushState()
    }
}
