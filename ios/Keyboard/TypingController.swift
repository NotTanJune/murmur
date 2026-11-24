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
            stripHeight: DS.Keyboard.stripHeight,
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

    /// A word is being typed, so the strip's leading cell has no room for the history icon.
    var isTypingWord: Bool {
        suggestions.contains { $0.kind == .typed || $0.kind == .completion }
    }

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

    @ObservationIgnored private static let log = Logger(subsystem: "ai.pivotstudio.murmur", category: "keyboard")

    init(proxy: @escaping () -> UITextDocumentProxy?) {
        self.proxy = proxy
        // Portrait at the reference width until the first layout says otherwise.
        let initial = KeyboardMetrics(
            width: DS.Keyboard.referenceWidth, isLandscape: false,
            constants: .keyboard(isLandscape: false))
        metrics = initial
        engine = TypingEngine(metrics: initial)
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
        flushState()
    }

    // MARK: - The plane

    /// The plane the keyboard view made. It can be made again (the emoji panel replaces it for a
    /// while), so this only points at the newest one and gives it the current state.
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

    private var currentState: KeyPlaneState {
        KeyPlaneState(
            frames: engine.frames, page: engine.page, shift: engine.shift,
            returnTitle: traits.returnKeyTitle, returnProminent: returnIsProminent)
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
            do { model = try TypingModel.bundled() } catch {
                Self.log.error("word model did not load: \(String(describing: error), privacy: .public)")
            }
        }
        readTraits()
        resetFieldState()
        engine.setPage(traits.keyboardKind == .number ? .numbers : .letters)
        engine.setShift(.off)
        stateIsDirty = true
        recomputeAutoShift()
        refreshSuggestions()
        flushState()
    }

    /// The host changed the text, the selection or the field. Traits can differ between fields,
    /// so they are read again; the shift key and the strip follow the text.
    func textDidChange() {
        let id = proxy()?.documentIdentifier
        if id != documentID { resetFieldState() }
        readTraits()
        recomputeAutoShift()
        refreshSuggestions()
        flushState()
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

    func handle(_ event: TouchEvent) {
        let effects = engine.handle(event, bias: [:])
        guard !effects.isEmpty else { return }
        apply(effects)
    }

    /// Applies the engine's effects in order. Typing effects go through the text rules; the rest
    /// are calls on the plane. Once the batch is done, a change to the text re-evaluates shift
    /// and the suggestions, and a changed page or shift goes to the plane.
    private func apply(_ effects: [TypingEffect]) {
        var textChanged = false
        for effect in effects {
            switch effect {
            case .insert(let text, _):
                typeInsert(text)
                textChanged = true
            case .deleteBackward(let count):
                deleteBackward(count)
                textChanged = true
            case .deleteWordBackward:
                deleteWordBackward()
                textChanged = true
            case .moveCursor(let offset):
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

    /// One typed string. A single character goes through the rules; anything longer (an accent
    /// the engine already cased, a double-space replacement) goes in as it is.
    private func typeInsert(_ text: String) {
        guard let proxy = proxy() else { return }
        guard text.count == 1, let mark = text.first else {
            pending.disarm()
            lastSpaceTime = nil
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

        if textRulesApply, let fix = TextRules.standaloneI(before: before, typed: mark) {
            perform(fix)
            before = String(before.dropLast()) + "I"
        }

        switch mark {
        case "'", "\"":
            proxy.insertText(TextRules.smartQuote(mark, before: before, enabled: traits.smartQuotes && isProseField))
        case "-":
            if let dash = TextRules.smartDash(before: before, enabled: traits.smartDashes && isProseField) {
                perform(dash)
            } else {
                proxy.insertText("-")
            }
        default:
            proxy.insertText(String(mark))
        }
    }

    private func typeSpace(before: String, proxy: UITextDocumentProxy) {
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
        if textRulesApply, let fix = TextRules.standaloneI(before: before, typed: " ") {
            perform(fix)
        }
        proxy.insertText(" ")
        lastSpaceTime = time
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
        proxy()?.insertText(text)
        textChangedByKeys()
        flushState()
    }

    func deleteExternal() {
        deleteBackward(1)
        textChangedByKeys()
        flushState()
    }

    /// Dictation typed into the field on its own. Shift and the strip catch up.
    func noteDictationInserted() {
        pending.disarm()
        lastSpaceTime = nil
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
        recomputeAutoShift()
        refreshSuggestions()
    }

    /// Turns shift on when the text asks for a capital next, and takes back only a shift that
    /// the text itself turned on. A tapped shift stays; caps lock is never touched.
    private func recomputeAutoShift() {
        guard let proxy = proxy() else { return }
        let wants = TextRules.autoShift(
            before: proxy.documentContextBeforeInput ?? "", autocapitalization: traits.autocapitalization)
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

    private func refreshSuggestions() {
        var next: [Suggestion] = []
        if suggestionsAllowed, let model, let proxy = proxy(),
            proxy.documentContextAfterInput?.first?.isLetter != true
        {
            let before = String((proxy.documentContextBeforeInput ?? "").suffix(400))
            next = SuggestionEngine.suggestions(before: before, model: model)
        }
        if next != suggestions { suggestions = next }
    }

    /// A tap on a strip cell: the typed word is replaced by the suggestion and a space is typed
    /// after it, which `PendingSpace` then lets the next space press, or a closing mark, take.
    /// The model stores a straight apostrophe, so smart quotes turn it curly here.
    func choose(_ suggestion: Suggestion) {
        guard let proxy = proxy() else { return }
        KeyFeedback.press()
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
