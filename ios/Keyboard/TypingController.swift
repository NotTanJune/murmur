import MurmurDesign
import MurmurKit
import MurmurTyping
import Observation
import OSLog
import UIKit

extension MetricsConstants {
    /// The stock keyboard's measurements for one orientation, filled from the design tokens.
    /// `MurmurTyping` cannot import `MurmurDesign`, so the iPhone target does it here.
    ///
    @MainActor
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
    /// The height of the key plane, for the SwiftUI layer, which keeps that much clear under the
    /// strip. Observed, unlike `planeHeight`, which the view controller reads at each layout.
    private(set) var planeSpace: CGFloat = 0

    /// The word autocorrect replaced, while its undo offer shows: the strip's left suggestion
    /// cell is the undo chip with this word. Nil when no offer is live.
    private(set) var undoChip: String?

    /// The best reading of the swipe in progress, for the strip's centre cell. Nil when no swipe is
    /// under way or the decoder has no reading yet. While it is set the strip shows only this.
    private(set) var swipePreview: String?

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
    /// The strip is computed here, off the main thread; see `refreshSuggestions`.
    @ObservationIgnored private let suggestionQueue = DispatchQueue(
        label: "ai.pivotstudio.murmur.suggestions", qos: .userInitiated)
    /// Counts strip refreshes, read on both queues, so a superseded result is dropped.
    @ObservationIgnored private let suggestionGeneration = OSAllocatedUnfairLock(initialState: 0)
    @ObservationIgnored private var biasTask: Task<Void, Never>?

    // Smart predictions: the language model behind the strip (`SmartPredictions`,
    // `NextWordPredictor`). The pair model answers first and always; the model's answer for the
    // same word boundary replaces it when it is there.
    @ObservationIgnored private let smart = SmartPredictions.shared
    /// The model's answer for the newest word boundary. Written on the main actor, read by the
    /// strip's pass on `suggestionQueue`.
    @ObservationIgnored private let prediction = OSAllocatedUnfairLock<WordPrediction?>(initialState: nil)
    /// The boundary last sent to the model, so one word asks once however many letters follow.
    @ObservationIgnored private var requestedBoundary: String?
    /// The text the newest strip pass was scheduled for, and the generation of the last pass
    /// that reached the strip: a prediction that arrives after its pass redoes that pass.
    @ObservationIgnored private var stripText: String?
    @ObservationIgnored private var stripShownGeneration = 0

    // Swipe typing (Milestone 6). The logic is in `MurmurTyping` (`SwipeDecoder`, `SwipeInsertion`);
    // this is the state it needs.
    /// The decoder for the letters page's frames. Nil until the word model has loaded.
    @ObservationIgnored private var swipeDecoder: SwipeDecoder?
    /// The swiped word that is still the last thing typed, with the other readings the strip
    /// offers. Dropped by anything else that edits the text.
    @ObservationIgnored private var swipeOffer: SwipeOffer?
    /// What the live decode needs from the text, read once when the swipe starts: the text cannot
    /// change under a swipe (a second finger ends it), and the proxy is a round trip.
    @ObservationIgnored private var swipeLive: SwipeLive?
    /// Live decodes run here, off the main thread, and their results are dropped when a newer
    /// request or the end of the swipe has superseded them (`swipeLiveGeneration`).
    @ObservationIgnored private let swipeQueue = DispatchQueue(
        label: "ai.pivotstudio.murmur.swipe", qos: .userInitiated)
    @ObservationIgnored private var swipeLiveGeneration = 0
    @ObservationIgnored private var lastLiveDecode: TimeInterval = 0

    private struct SwipeLive {
        var previous: Int?
        var sentenceCapital: Bool
        var lexicon: UserLexicon
    }

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
        planeSpace = initial.height - initial.constants.stripHeight
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
        if planeSpace != planeHeight { planeSpace = planeHeight }
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
        rebuildSwipeDecoder()
    }

    /// The swipe decoder reads the same letters frames as the tap decoder and follows them.
    private func rebuildSwipeDecoder() {
        swipeDecoder = model.map { SwipeDecoder(model: $0, frames: lettersFrames) }
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
        if !modelLoaded {
            modelLoaded = true
            do {
                let loaded = try TypingModel.bundled()
                model = loaded
                autocorrector = Autocorrector(model: loaded, lettersFrames: lettersFrames)
                rebuildSwipeDecoder()
                buildBias(model: loaded)
            } catch {
                Self.log.error("word model did not load: \(String(describing: error), privacy: .public)")
            }
        }
        preparePredictions()
        refreshLexicon(force: true)
        readTraits()
        resetFieldState()
        engine.setPage(traits.keyboardKind == .number ? .numbers : .letters)
        engine.setShift(.off)
        stateIsDirty = true
        refreshText()
        flushState()
    }

    /// The keyboard went away: drop what belongs to the last field's typing.
    func keyboardDisappeared() {
        undo = nil
        tracker.reset()
        cancelLiveSwipe()
        swipeOffer = nil
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

    /// The field's identity. `UITextDocumentProxy.documentIdentifier` is declared as a
    /// non-optional `UUID`, but a host can leave it nil, and bridging that nil to `UUID` traps:
    /// it crashed the keyboard in `runTextRefresh` on 2026-11-25. So it is read through the
    /// Objective-C runtime as an optional object.
    private func currentDocumentID() -> UUID? {
        guard let object = proxy() as? NSObject else { return nil }
        let selector = NSSelectorFromString("documentIdentifier")
        guard object.responds(to: selector),
              let value = object.perform(selector)?.takeUnretainedValue() as? NSUUID
        else { return nil }
        return value as UUID
    }

    private func resetFieldState() {
        documentID = currentDocumentID()
        pending.disarm()
        lastSpaceTime = nil
        autoShifted = false
        // Taps and an undo offer belong to the text of the last field.
        tracker.reset()
        undo = nil
        swipeOffer = nil
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
            autocapitalization: autoCapitals ? Self.mode(of: capitalisation) : .none,
            smartQuotes: quotes != .no,
            smartDashes: dashes != .no,
            returnKeyTitle: Self.title(for: returnKey))
        let prominent = Self.isProminent(returnKey)
        if next != traits || prominent != returnIsProminent {
            traits = next
            returnIsProminent = prominent
            // An email or web address field has its own bottom row on the letters page.
            engine.setField(next.keyboardKind)
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

    /// One finger event, from the plane: the engine decides, `apply` carries it out.
    func handle(_ event: TouchEvent) {
        // Whether a touch may swipe is decided as the finger lands, from the setting as it stands
        // now.
        if case .began = event {
            recheckAutoShift()
            engine.swipeEnabled = swipeAllowed
            plane?.swipeTrailWidth = swipeTrailWidth
        }
        let effects = engine.handle(event, bias: biasForTouch())
        if !effects.isEmpty { apply(effects) }
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
                textChanged = true
            case .deleteBackward(let count):
                // The one delete that follows a replacement keeps its offer (and shows it);
                // anything else ends it. The taps of the word lose the letters deleted.
                // A delete after a swipe takes one character, like any other delete: the owner
                // asked for that over deleting the whole word (2026-11-25). It ends the offer.
                swipeOffer = nil
                undo = undo?.afterDelete(count: count)
                tracker.dropLast(count)
                deleteBackward(count)
                textChanged = true
            case .deleteWordBackward:
                undo = nil
                swipeOffer = nil
                tracker.reset()
                deleteWordBackward()
                textChanged = true
            case .moveCursor(let offset):
                undo = nil
                swipeOffer = nil
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
            case .swipeUpdate(let path):
                swipeUpdate(path)
            case .swipeEnded(let path, let times):
                if swipeEnded(path: path, times: times) { textChanged = true }
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
        // A swiped word is the last thing typed until this key; it is owed a space, which a letter
        // claims below and anything else leaves alone.
        let owed = swipeOffer
        swipeOffer = nil
        guard let proxy = proxy() else { return }
        guard text.count == 1, let mark = text.first else {
            pending.disarm()
            lastSpaceTime = nil
            tracker.reset()
            proxy.insertText(text)
            return
        }
        // An ordinary letter or digit goes straight in. Nothing below applies to it unless a
        // suggestion's space or a swipe's owed space is waiting, and reading the text before the
        // cursor first is a round trip to the host app on the main thread for every key: the
        // owner felt typing as "heavy" beside the stock keyboard on 2026-11-25, which reads
        // nothing and runs inside the app.
        if owed == nil, !pending.isArmed, mark.isLetter || mark.isNumber {
            lastSpaceTime = nil
            proxy.insertText(text)
            if mark.isLetter, let tap {
                tracker.append(letter: text, at: tap)
            } else {
                tracker.reset()
            }
            return
        }
        var before = proxy.documentContextBeforeInput ?? ""

        if mark == " " {
            typeSpace(before: before, proxy: proxy, finishesWord: owed == nil)
            return
        }

        // A mark that closes a word takes the space a tapped suggestion typed.
        if pending.takesSpace(before: mark), before.last == " " {
            proxy.deleteBackward()
            before.removeLast()
        }
        pending.disarm()
        lastSpaceTime = nil

        // A closing mark ends the word, so the word is checked before the mark goes in. A swiped
        // word was chosen by the decoder and is not checked again.
        if PendingSpace.closingMarks.contains(mark), owed == nil {
            before = finishWord(before: before, terminator: String(mark))
        }

        if textRulesApply, autoCapitals, let fix = TextRules.standaloneI(before: before, typed: mark) {
            perform(fix)
            before = String(before.dropLast()) + "I"
        }

        // The space a swipe left owed goes in ahead of a letter. Marks and the space key sit
        // against the word, so punctuation never has a space to take back.
        if let owed, mark.isLetter, !swipesJoin, owed.isConsistent(with: before) {
            proxy.insertText(" ")
            before += " "
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

    private func typeSpace(before: String, proxy: UITextDocumentProxy, finishesWord: Bool = true) {
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
            // With auto-capitalisation off the period still goes in, without the shift after it.
            perform(autoCapitals ? period : period.filter { if case .setShift = $0 { false } else { true } })
            lastSpaceTime = nil
            return
        }
        if finishesWord {
            before = finishWord(before: before, terminator: " ")
            if textRulesApply, autoCapitals, let fix = TextRules.standaloneI(before: before, typed: " ") {
                perform(fix)
            }
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
        let result = autocorrector?.evaluate(
            textBefore: String(before.suffix(Self.contextLimit)), tracker: tracker, field: traits)
        guard let result, let replacement = result.replacement else { return before }

        var typed = smartApostrophes(replacement.text)
        // "im" becomes "I'm" by the contraction rule; with auto-capitalisation off a word typed
        // in lowercase keeps its lowercase start ("i'm").
        if !autoCapitals, result.word.text == result.word.text.lowercased(), let first = typed.first, first.isUppercase {
            typed = first.lowercased() + typed.dropFirst()
        }
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
        swipeOffer = nil
        tracker.reset()
        pending.disarm()
        lastSpaceTime = nil
        textChangedByKeys()
        flushState()
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
        // A swiped word is followed by an owed space, so the next letter starts a new word and the
        // swiped one's letters say nothing about it.
        guard swipeOffer == nil else { return [:] }
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
        swipeOffer = nil
        tracker.reset()
        proxy()?.insertText(text)
        textChangedByKeys()
        flushState()
    }

    func deleteExternal() {
        undo = nil
        swipeOffer = nil
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
        swipeOffer = nil
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
            let id = currentDocumentID()
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
        if let offer = swipeOffer, !offer.isConsistent(with: before) { swipeOffer = nil }
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
    /// Settings, Auto-capitalisation. Off, the field reads as asking for no capitals, so no
    /// automatic shift is set anywhere; a lone "i" stays as typed and "im" becomes "i'm".
    private var autoCapitals: Bool { Settings.shared.autoCapitalise }

    /// The trail's thickness for the Settings choice.
    private var swipeTrailWidth: CGFloat {
        switch Settings.shared.swipeTrail {
        case .thin: DS.Keyboard.swipeTrailWidthThin
        case .regular: DS.Keyboard.swipeTrailWidth
        case .thick: DS.Keyboard.swipeTrailWidthThick
        case .bold: DS.Keyboard.swipeTrailWidthBold
        }
    }

    /// At a touch-down: a shift that this keyboard turned on by itself is checked against the
    /// text as it stands now, and taken back if the text no longer starts a sentence. Auto-shift
    /// is otherwise only worked out after a change to the text or a call from the host, and a
    /// host can call with an empty or partial context (Notes after a pause is the suspect), which
    /// reads as a sentence start and leaves shift on until the next key. On 2026-11-25 words
    /// swiped or typed after a pause came out capitalised mid-sentence. The read costs one call
    /// to the proxy and only happens while an automatic shift is on. A shift the owner tapped is
    /// never touched.
    private func recheckAutoShift() {
        guard autoShifted, engine.shift == .on, let proxy = proxy() else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        guard !TextRules.autoShift(before: before, autocapitalization: traits.autocapitalization) else { return }
        engine.setShift(.off)
        autoShifted = false
        stateIsDirty = true
        flushState()
    }

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
        // Every refresh supersedes the ones before it; a result computed for older text is
        // dropped when it arrives.
        let generation = suggestionGeneration.withLock { value -> Int in
            value += 1
            return value
        }
        // Right after a swipe the strip offers the swipe's other readings, until anything else
        // edits the text. With none to offer it falls through to the word's usual strip.
        if let offer = swipeOffer, !offer.alternatives.isEmpty {
            let cells = SwipeInsertion.stripCells(for: offer)
            if cells != suggestions { suggestions = cells }
            return
        }
        guard suggestionsAllowed, let model, after?.first?.isLetter != true else {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        refreshLexicon()
        // The language model predicts from the text up to the start of the word being typed, so
        // the strip's text is cut there and not at a fixed distance from the cursor: the same
        // word then names the same boundary at every letter, however long the text is.
        let tail: String
        if let typed = SuggestionEngine.typedLength(before: before) {
            let boundary = String(before.dropLast(typed).suffix(Self.contextLimit))
            tail = boundary + before.suffix(typed)
            requestPrediction(at: boundary, model: model)
        } else {
            tail = String(before.suffix(Self.contextLimit))
        }
        stripText = tail
        // The strip is worked out on a background queue, and only once the keys have been quiet
        // for `DS.Keyboard.suggestionQuietSeconds`. A fast typist's next tap arrives 80 to 150 ms
        // after the last, so typing never waits on the strip. This was first done on the theory
        // that a busy main thread lost taps; it did not (they were lost in the clear gaps
        // between keycaps, see `touchBackingUIColor`), and it stays because it is cheaper.
        scheduleStrip(generation: generation, text: tail, model: model, delay: DS.Keyboard.suggestionQuietSeconds)
    }

    /// Works the strip out for `text` on the background queue after `delay` and shows it, unless
    /// a newer refresh has superseded `generation` by then. The pass reads the language model's
    /// prediction when it runs, not when it is scheduled, so an answer that arrives during the
    /// quiet time is in the strip the first time it is drawn.
    private func scheduleStrip(generation: Int, text tail: String, model: TypingModel, delay: Double) {
        let tracker = self.tracker
        let field = traits
        let autocorrector = self.autocorrector
        let latest = suggestionGeneration
        let prediction = self.prediction
        let capitalisesStarts = autoCapitals
        suggestionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard latest.withLock({ $0 }) == generation else { return }
            let answer = prediction.withLock { $0 }
            var next = SuggestionEngine.suggestions(
                before: tail, model: model, prediction: answer, capitalisesStarts: capitalisesStarts)
            // Mid-word, a confident correction takes the centre cell, the typed word stays on
            // the left in quotes, and one completion stays on the right. The evaluation is the
            // one the word's end will make.
            if next.first?.kind == .typed,
                let fix = autocorrector?.evaluate(textBefore: tail, tracker: tracker, field: field)?.stripCorrection
            {
                next = SuggestionEngine.merging(correction: fix, into: next)
            }
            let result = next
            Task { @MainActor [weak self] in
                guard let self, self.suggestionGeneration.withLock({ $0 }) == generation else { return }
                self.stripShownGeneration = generation
                if result != self.suggestions { self.suggestions = result }
            }
        }
    }

    /// Loads the language model as the keyboard appears, so it is ready before the first word
    /// and ahead of Bark (`SmartPredictions` says why the order matters). Called before the
    /// dictation's own `keyboardAppeared`, which is where Bark's load starts.
    private func preparePredictions() {
        guard Settings.shared.smartPredictions, let model else {
            smart.turnOff()
            return
        }
        smart.prepare(words: model)
    }

    /// Sends a word boundary to the language model, once. The pass starts at the keystroke that
    /// made the boundary (the space) and not after the strip's quiet time, so on a fast phone the
    /// answer is there before the strip is first drawn and the pair model's words never flash;
    /// when it is later than that, the strip shows the pair model's words and then swaps.
    private func requestPrediction(at boundary: String, model: TypingModel) {
        guard Settings.shared.smartPredictions else {
            smart.turnOff()
            if requestedBoundary != nil {
                requestedBoundary = nil
                prediction.withLock { $0 = nil }
            }
            return
        }
        guard boundary != requestedBoundary else { return }
        requestedBoundary = boundary
        smart.request(boundary, words: model) { [weak self] in self?.predictionArrived($0) }
    }

    /// The model answered. An answer for a boundary the text has left is dropped. Otherwise it is
    /// kept for the strip's passes, and if the strip already shows this text without it, the pass
    /// is run again at once: the same generation, so a newer refresh still wins.
    private func predictionArrived(_ answer: WordPrediction) {
        guard answer.boundary == requestedBoundary else { return }
        prediction.withLock { $0 = answer }
        let generation = suggestionGeneration.withLock { $0 }
        guard stripShownGeneration == generation, let model, let text = stripText else { return }
        scheduleStrip(generation: generation, text: text, model: model, delay: 0)
    }

    /// A tap on a strip cell: the typed word is replaced by the suggestion and a space is typed
    /// after it, which `PendingSpace` then lets the next space press, or a closing mark, take.
    /// The model stores a straight apostrophe, so smart quotes turn it curly here.
    func choose(_ suggestion: Suggestion) {
        guard let proxy = proxy() else { return }
        if let offer = swipeOffer, let next = offer.choosing(suggestion.text) {
            chooseSwipeReading(next, replacing: offer, proxy: proxy)
            return
        }
        swipeOffer = nil
        KeyFeedback.press()
        undo = nil
        tracker.reset()
        let before = proxy.documentContextBeforeInput ?? ""
        if suggestion.kind == .typed, textRulesApply, autoCapitals,
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

    // MARK: - Swipe typing

    /// Whether a touch landing now may become a swipe: the setting is on, VoiceOver is off (it
    /// activates keys, it does not drag), the word model has loaded, and the field is not a
    /// password, a number or a phone field. A field that refuses autocorrection still swipes: a
    /// swipe is how the word was typed, not a correction of it, and mail apps turn autocorrection
    /// off in fields the owner writes whole messages in (asked for on 2026-11-25, with web and
    /// email address fields). The engine adds the page: only the letters page swipes.
    private var swipeAllowed: Bool {
        guard swipeDecoder != nil, Settings.shared.swipeTyping, !UIAccessibility.isVoiceOverRunning,
            !traits.isSecure
        else { return false }
        switch traits.keyboardKind {
        case .number, .phone: return false
        case .default, .webSearch, .url, .email: return true
        }
    }

    /// In a web or email address field swiped words join with no space between them or before
    /// the next letter, because an address has none, and nothing before them is context.
    private var swipesJoin: Bool {
        traits.keyboardKind == .url || traits.keyboardKind == .email
    }

    /// The path so far, at each move of a swipe, and an empty one when the swipe was cancelled.
    /// Draws the trail, and about every `swipeLiveDecodeSeconds` decodes the path off the main
    /// thread and shows the best reading in the strip's centre cell. A result that a newer one or
    /// the swipe's end has overtaken is dropped.
    private func swipeUpdate(_ path: [CGPoint]) {
        plane?.setSwipePath(path)
        guard !path.isEmpty else {
            cancelLiveSwipe()
            return
        }
        let time = now
        if swipeLive == nil {
            beginLiveSwipe()
            lastLiveDecode = time
        }
        guard let decoder = swipeDecoder, let live = swipeLive,
            time - lastLiveDecode >= DS.Keyboard.swipeLiveDecodeSeconds
        else { return }
        lastLiveDecode = time
        swipeLiveGeneration += 1
        let generation = swipeLiveGeneration
        swipeQueue.async { [weak self] in
            let best = decoder.decode(
                path: path, times: nil, previous: live.previous, lexicon: live.lexicon, limit: 1
            ).first?.text
            Task { @MainActor [weak self] in
                self?.showSwipePreview(best, generation: generation)
            }
        }
    }

    /// Reads what the live decode needs from the text, once, as the swipe starts.
    private func beginLiveSwipe() {
        guard let proxy = proxy() else { return }
        refreshLexicon()
        let before = String(
            (proxy.documentContextBeforeInput ?? "").suffix(Self.contextLimit))
        swipeLive = SwipeLive(
            previous: swipesJoin ? nil : SwipeInsertion.previousWord(before: before).flatMap { model?.id(of: $0) },
            sentenceCapital: !swipesJoin && SwipeInsertion.wantsCapital(
                before: before, autocapitalization: traits.autocapitalization),
            lexicon: autocorrector?.lexicon ?? .empty)
    }

    private func showSwipePreview(_ word: String?, generation: Int) {
        guard generation == swipeLiveGeneration, let live = swipeLive else { return }
        let text = word.map {
            SwipeInsertion.cased(
                smartApostrophes($0), shift: engine.shift, sentenceCapital: live.sentenceCapital,
                capitalisesI: autoCapitals)
        }
        if text != swipePreview { swipePreview = text }
    }

    /// The swipe is over (lifted, cancelled or ended by a second finger): late live results are
    /// dropped and the strip's centre cell goes back to the suggestions.
    private func cancelLiveSwipe() {
        swipeLiveGeneration += 1
        swipeLive = nil
        if swipePreview != nil { swipePreview = nil }
    }

    /// Types the swiped word, when the decoder has one. Returns whether it typed.
    ///
    /// The decode runs here, on the main thread, at the lift. Its cost is the benchmark's: under a
    /// millisecond at the 99th percentile in a release build on a Mac, a few on a phone, in the
    /// time the keyboard spends on a key tap. Doing it synchronously also keeps the order: the
    /// word is in the field before the next effect of the same event (a second finger's delete) and
    /// before any later key's insert, which an asynchronous decode could not promise without a
    /// queue of pending inserts.
    ///
    /// The word goes in after a space unless the text before the cursor is empty, ends in
    /// whitespace or an opening mark. Shift, caps lock and a sentence start case it. The space
    /// after it is not typed: it is owed (`SwipeOffer`). A typed word before it is finished first,
    /// as a space would finish it (autocorrect and a lone "i"), unless that word was itself swiped.
    private func swipeEnded(path: [CGPoint], times: [TimeInterval]) -> Bool {
        plane?.setSwipePath([])
        cancelLiveSwipe()
        undo = nil
        tracker.reset()
        guard let proxy = proxy(), let decoder = swipeDecoder, let model else { return false }
        refreshLexicon()
        var before = proxy.documentContextBeforeInput ?? ""
        let tail = String(before.suffix(Self.contextLimit))
        let previousWord = swipesJoin ? nil : SwipeInsertion.previousWord(before: tail)
        let previous = previousWord.flatMap { model.id(of: $0) }

        let candidates = decoder.decode(
            path: path, times: times, previous: previous, lexicon: autocorrector?.lexicon ?? .empty,
            limit: 1 + SwipeOffer.alternativeLimit)
        guard !candidates.isEmpty else { return false }

        let needsSpace = !swipesJoin && SwipeInsertion.needsLeadingSpace(before: before)
        if needsSpace, swipeOffer == nil, !WordAtCursor.trailingWord(of: before).isEmpty {
            before = finishWord(before: before, terminator: " ")
            if textRulesApply, autoCapitals, let fix = TextRules.standaloneI(before: before, typed: " ") {
                perform(fix)
            }
        }
        swipeOffer = nil

        let shift = engine.shiftAtSwipeEnd
        let capital =
            shift == .off && !swipesJoin
            && SwipeInsertion.wantsCapital(before: before, autocapitalization: traits.autocapitalization)
        var readings: [String] = []
        for candidate in candidates {
            let reading = SwipeInsertion.cased(
                smartApostrophes(candidate.text), shift: shift, sentenceCapital: capital,
                capitalisesI: autoCapitals)
            if !readings.contains(reading) { readings.append(reading) }
        }
        // A contact's name that is also a plain word types as the plain word; its capital form is
        // the first alternative in the strip.
        if let entry = autocorrector?.lexicon.entry(for: candidates[0].text), !entry.respellsKnownWords {
            let name = SwipeInsertion.cased(
                smartApostrophes(entry.display), shift: shift, sentenceCapital: capital, capitalisesI: autoCapitals)
            if !readings.contains(name) { readings.insert(name, at: 1) }
        }
        proxy.insertText((needsSpace ? " " : "") + readings[0])
        swipeOffer = SwipeOffer(readings: readings)
        undo = nil
        pending.disarm()
        lastSpaceTime = nil
        if engine.spendShiftAfterSwipe() {
            autoShifted = false
            stateIsDirty = true
        }
        return true
    }

    /// A tap on one of the strip's other readings replaces the swiped word with it. The space
    /// the swipe typed before it stays, and the space after it stays owed. The word that was
    /// typed becomes one of the alternatives.
    private func chooseSwipeReading(_ next: SwipeOffer, replacing offer: SwipeOffer, proxy: UITextDocumentProxy) {
        KeyFeedback.press()
        guard offer.isConsistent(with: proxy.documentContextBeforeInput ?? "") else {
            swipeOffer = nil
            textChangedByKeys()
            flushState()
            return
        }
        for _ in 0..<offer.word.count { proxy.deleteBackward() }
        proxy.insertText(next.word)
        swipeOffer = next
        undo = nil
        tracker.reset()
        pending.disarm()
        lastSpaceTime = nil
        textChangedByKeys()
        flushState()
    }
}
