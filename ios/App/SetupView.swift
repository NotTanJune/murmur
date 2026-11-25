import AVFoundation
import MurmurDesign
import MurmurKit
import Speech
import SwiftUI
import UIKit

/// What the Setup tab shows, read from the system and from the files the keyboard writes
/// into the App Group. Nothing here is cached: `refresh()` reads it all again.
@MainActor @Observable
final class SetupStatus {
    private(set) var microphone = AVAudioApplication.shared.recordPermission
    private(set) var speech = SFSpeechRecognizer.authorizationStatus()
    /// The keyboard is in the active input modes, or has reported once from the App Group.
    private(set) var keyboardAdded = false
    /// Nil until the keyboard has run and reported.
    private(set) var hasFullAccess: Bool?
    /// What the keyboard last said about Bark; nil before it has run, or for a value this
    /// version does not know, which reads as "not in use".
    private(set) var keyboardBark: KeyboardStatus.BarkState?
    private(set) var keyboardReported = false
    /// Touch-down to the first audio of the keyboard's last hold, in ms; nil before one.
    private(set) var lastStartLatencyMs: Int?
    /// The keyboard process's Bark load and warm-up, and where its last delivered hold's
    /// release time went; nil until it has reported them.
    private(set) var barkLoadSeconds: Double?
    private(set) var barkWarmupSeconds: Double?
    private(set) var lastReleaseEngineMs: Int?
    private(set) var lastReleaseCleanupMs: Int?
    private(set) var lastReleaseEngine: String?
    /// How the keyboard's page last captured audio (`recordOnly` or `playAndRecord`); nil until
    /// it has delivered audio and reported.
    private(set) var captureMode: String?
    /// The keyboard's requested and actual height, in points; nil until it has reported.
    private(set) var emojiPanelRequestedHeight: Int?
    private(set) var emojiPanelShownHeight: Int?
    /// The keyboard process's footprint at its last sample and its peak, in MB; nil until it
    /// has reported them.
    private(set) var footprintMB: Double?
    private(set) var peakFootprintMB: Double?
    /// The keys' counters since the keyboard last appeared; nil until it has reported them.
    private(set) var typingTouchDowns: Int?
    private(set) var typingCancelled: Int?
    private(set) var typingOffKey: Int?
    private(set) var typingSlowestHandleMs: Double?
    private(set) var typingMaxDeliveryMs: Double?
    private(set) var typingSlowestAutocorrectMs: Double?
    /// The strip's language model as the keyboard last reported it; nil until it has.
    private(set) var predictionState: String?
    private(set) var predictionLoadSeconds: Double?
    private(set) var predictionLastMs: Double?
    private(set) var predictionFootprintMB: Double?
    /// Temporary, with `KeyboardStatus`' counters of the same names.
    private(set) var predictionAnswers: Int?
    private(set) var predictionStale: Int?
    private(set) var stripPasses: Int?
    private(set) var stripPassesWithPrediction: Int?
    private(set) var predictionFreeMB: Double?
    /// Bark stopped the keyboard last time, and nothing live is using the marker.
    private(set) var markerArmed = false
    private(set) var isShared = PhoneEnvironment.isShared

    /// How long after its last report a keyboard still counts as loading Bark. The keyboard
    /// reports when a load starts and when it ends, so a load that outlasts this with the
    /// marker still armed is taken to have killed it.
    static let loadingStaleAfter: TimeInterval = 120

    func refresh() {
        microphone = AVAudioApplication.shared.recordPermission
        speech = SFSpeechRecognizer.authorizationStatus()
        let reported = KeyboardStatus.read()
        keyboardReported = reported != nil
        lastStartLatencyMs = reported?.lastStartLatencyMs
        barkLoadSeconds = reported?.barkLoadSeconds
        barkWarmupSeconds = reported?.barkWarmupSeconds
        lastReleaseEngineMs = reported?.lastReleaseEngineMs
        lastReleaseCleanupMs = reported?.lastReleaseCleanupMs
        lastReleaseEngine = reported?.lastReleaseEngine
        captureMode = reported?.captureMode
        emojiPanelRequestedHeight = reported?.emojiPanelRequestedHeight
        emojiPanelShownHeight = reported?.emojiPanelShownHeight
        footprintMB = reported?.footprintMB
        peakFootprintMB = reported?.peakFootprintMB
        typingTouchDowns = reported?.typingTouchDowns
        typingCancelled = reported?.typingCancelled
        typingOffKey = reported?.typingOffKey
        typingSlowestHandleMs = reported?.typingSlowestHandleMs
        typingMaxDeliveryMs = reported?.typingMaxDeliveryMs
        typingSlowestAutocorrectMs = reported?.typingSlowestAutocorrectMs
        predictionState = reported?.predictionState
        predictionLoadSeconds = reported?.predictionLoadSeconds
        predictionLastMs = reported?.predictionLastMs
        predictionFootprintMB = reported?.predictionFootprintMB
        predictionAnswers = reported?.predictionAnswers
        predictionStale = reported?.predictionStale
        stripPasses = reported?.stripPasses
        stripPassesWithPrediction = reported?.stripPassesWithPrediction
        predictionFreeMB = reported?.predictionFreeMB
        hasFullAccess = reported?.hasFullAccess
        keyboardBark = reported.flatMap { KeyboardStatus.BarkState(rawValue: $0.barkState) }
        keyboardAdded = Self.activeInputModesContainKeyboard() || reported != nil
        // The keyboard arms the marker before it loads Bark and disarms it after a good hold, so
        // an armed marker is the sign of a death only when the keyboard is not loading or
        // running Bark right now. A keyboard that found it armed at launch reports
        // `stoppedLastTime`. One that died mid-load never reports again and its last report
        // still says `loading`, so a `loading` report older than `loadingStaleAfter` reads as
        // stopped too.
        let armed = CrashMarker(directory: MurmurKit.AppStorage.directory).isArmed
        let loadingIsStale = keyboardBark == .loading
            && reported.map { Date().timeIntervalSince($0.lastSeen) > Self.loadingStaleAfter } ?? false
        markerArmed = armed && (loadingIsStale || (keyboardBark != .loading && keyboardBark != .ready))
        isShared = PhoneEnvironment.isShared
        BarkDownload.shared.refresh()
    }

    func requestMicrophone() async {
        _ = await AVAudioApplication.requestRecordPermission()
        refresh()
    }

    func requestSpeech() async {
        _ = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        refresh()
    }

    func tryBarkAgain() {
        CrashMarker(directory: MurmurKit.AppStorage.directory).disarm()
        refresh()
    }

    /// `UITextInputMode` publishes no identifier, but an extension's mode carries its bundle ID
    /// in the `identifier` key. Asked only when the object answers it, so a system that drops
    /// the key reads as "not found" here and falls back to the keyboard's own report.
    private static func activeInputModesContainKeyboard() -> Bool {
        let key = "identifier"
        return UITextInputMode.activeInputModes.contains { mode in
            guard mode.responds(to: NSSelectorFromString(key)),
                  let identifier = mode.value(forKey: key) as? String else { return false }
            return identifier.contains(PhoneEnvironment.keyboardBundleID)
        }
    }
}

/// The first tab: what the keyboard needs, and the one-tap way to each.
struct SetupView: View {
    @Environment(\.scenePhase) private var phase
    @State private var status = SetupStatus()
    /// The typing diagnostics switch; it turns itself off after `TypingDiagnostics.duration`.
    @State private var diagnosticsOn = TypingDiagnostics.expiry != nil
    /// The staged two-key test is armed until the keyboard starts it.
    @State private var stageTestArmed = TypingDiagnostics.stageTestArmed

    var body: some View {
        PhonePage(title: "Setup") {
            if status.markerArmed {
                stoppedCard
            }

            Card(title: "Permissions") {
                SetupRow(
                    title: "Microphone",
                    detail: status.microphone == .denied ? "Turned off. Allow it in Settings." : nil,
                    isDone: status.microphone == .granted
                ) {
                    switch status.microphone {
                    case .undetermined: Button("Allow") { Task { await status.requestMicrophone() } }
                    case .denied: OpenSettingsButton()
                    default: EmptyView()
                    }
                }
                SetupRow(
                    title: "Speech recognition",
                    detail: status.speech == .denied || status.speech == .restricted ? "Turned off. Allow it in Settings." : nil,
                    isDone: status.speech == .authorized
                ) {
                    switch status.speech {
                    case .notDetermined: Button("Allow") { Task { await status.requestSpeech() } }
                    case .denied, .restricted: OpenSettingsButton()
                    default: EmptyView()
                    }
                }
            }

            Card(title: "Keyboard") {
                SetupRow(
                    title: "Keyboard added",
                    detail: keyboardDetail,
                    isDone: status.keyboardAdded
                ) {
                    if !status.keyboardAdded { OpenSettingsButton() }
                }
                SetupRow(
                    title: "Full Access",
                    detail: fullAccessDetail,
                    isDone: status.hasFullAccess == true
                ) {
                    if status.hasFullAccess != true { OpenSettingsButton() }
                }
                if let line = captureModeLine {
                    Note(text: line)
                }
                if let line = emojiPanelLine {
                    Note(text: line)
                }
                if let line = memoryLine {
                    Note(text: line)
                }
                if let line = typingLine {
                    Note(text: line)
                }
                if let line = predictionLine {
                    Note(text: line)
                }
                ToggleRow(
                    title: "Typing diagnostics",
                    note: "Logs each key touch for 10 minutes so the Mac's live log can show dropped taps. It records what you type, stays on this iPhone, and is deleted when switched off.",
                    isOn: Binding(
                        get: { diagnosticsOn },
                        set: { on in
                            if on { TypingDiagnostics.turnOn() } else { TypingDiagnostics.turnOff() }
                            diagnosticsOn = on
                            if !on { stageTestArmed = false }
                        }
                    )
                )
                ToggleRow(
                    title: "Two-key test",
                    note: "Runs once, from your next key press, for 25 seconds: tap f and j in turn, fast, until \"[test done]\" is typed. The last 5 seconds type nothing.",
                    isOn: Binding(
                        get: { stageTestArmed },
                        set: { on in
                            if on { TypingDiagnostics.armStageTest() } else { TypingDiagnostics.disarmStageTest() }
                            stageTestArmed = on
                            diagnosticsOn = TypingDiagnostics.expiry != nil
                        }
                    )
                )
            }

            Card(title: "Typing lab") {
                TypingLab()
            }

            Card(title: "Model") {
                BarkModelRow()
                if let line = keyboardEngineLine {
                    Note(text: line)
                }
                if let line = barkTimingLine {
                    Note(text: line)
                }
                if let line = releaseTimingLine {
                    Note(text: line)
                }
            }

            if !status.isShared {
                Card(title: "Storage") {
                    Note(text: "Murmur cannot reach its shared storage, so the keyboard and this app would see different files. Reinstall the app from a signed build.")
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            status.refresh()
            diagnosticsOn = TypingDiagnostics.expiry != nil
            stageTestArmed = TypingDiagnostics.stageTestArmed
        }
        .onChange(of: phase) { _, now in
            if now == .active {
                status.refresh()
                diagnosticsOn = TypingDiagnostics.expiry != nil
                stageTestArmed = TypingDiagnostics.stageTestArmed
            }
        }
        // The keyboard writes its report while this tab is on screen, in another app's text
        // field or beside this one, so look again while the tab is visible.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: DS.Motion.statusPoll)
                status.refresh()
            }
        }
    }

    private var stoppedCard: some View {
        Card(title: "Bark") {
            Text("Bark stopped the keyboard last time")
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            Note(text: "iOS ended the keyboard while it was loading Bark, so it now uses Apple's transcriber.")
            Button("Try Bark again") { status.tryBarkAgain() }
                .buttonStyle(KeyButtonStyle(kind: .primary))
        }
    }

    /// How to add the keyboard, or once it is added, how fast its last hold started listening.
    private var keyboardDetail: String? {
        guard status.keyboardAdded else {
            return "Settings, General, Keyboard, Keyboards, Add New Keyboard, Murmur."
        }
        // 0 ms means the pre-roll supplied the audio, which only a warm microphone has.
        return status.lastStartLatencyMs.map { $0 > 0 ? "Last start: \($0) ms" : "Last start: instant (warm microphone)" }
    }

    /// "Capture: record-only", from the keyboard's last report. Unknown values are not shown.
    private var captureModeLine: String? {
        switch status.captureMode {
        case "recordOnly": "Capture: record-only"
        case "playAndRecord": "Capture: play-and-record"
        default: nil
        }
    }

    /// "Keyboard height: 253 requested, 253 pt shown", from the keyboard's last layout. Equal
    /// means the system honoured the height constraint.
    private var emojiPanelLine: String? {
        guard let requested = status.emojiPanelRequestedHeight, let shown = status.emojiPanelShownHeight else { return nil }
        return "Keyboard height: \(requested) requested, \(shown) pt shown"
    }

    /// "Memory: 38 MB now · 41 MB peak", the keyboard process's physical footprint.
    private var memoryLine: String? {
        guard let now = status.footprintMB, let peak = status.peakFootprintMB else { return nil }
        return "Memory: \(Int(now.rounded())) MB now · \(Int(peak.rounded())) MB peak"
    }

    /// "Typing: 214 taps · 0 cancelled · 1 off-key · slowest 3.2 ms · delivery 18 ms", the
    /// keys' counters since the keyboard last appeared. Taps is touch-downs on any key; a
    /// cancelled touch typed nothing, an off-key lift typed its last key, the slowest is the
    /// longest `handle` and delivery the largest wait between a touch and its handling. Once a
    /// word has been checked, "autocorrect 2.1 ms" is the slowest check (parse, decode, policy).
    private var typingLine: String? {
        guard let downs = status.typingTouchDowns, let cancelled = status.typingCancelled,
            let offKey = status.typingOffKey, let slowest = status.typingSlowestHandleMs,
            let delivery = status.typingMaxDeliveryMs
        else { return nil }
        var line = "Typing: \(downs) taps · \(cancelled) cancelled · \(offKey) off-key · slowest \(String(format: "%.1f", slowest)) ms · delivery \(Int(delivery.rounded())) ms"
        // Zero means no word has been checked since the keyboard appeared.
        if let autocorrect = status.typingSlowestAutocorrectMs, autocorrect > 0 {
            line += " · autocorrect \(String(format: "%.1f", autocorrect)) ms"
        }
        return line
    }

    /// "Predictions: ready · loaded in 0.41 s · last 6 ms · +12 MB", the strip's language model
    /// in the keyboard process: its state, this process's load, the last prediction's forward
    /// pass and what the model added to the footprint. The other states say why it is not
    /// running.
    private var predictionLine: String? {
        guard let state = status.predictionState else { return nil }
        var line: String
        switch state {
        case "ready": line = "Predictions: ready"
        case "loading": line = "Predictions: loading"
        case "waiting": line = "Predictions: starts at the first key"
        case "off": line = "Predictions: off"
        case "missing": line = "Predictions: model not in this build"
        case "lowMemory": line = "Predictions: not enough memory, using the word-pair model"
        case "stoppedLastTime":
            line = "Predictions: stopped the keyboard last time. Turn Smart predictions off and on in Settings to try again."
        default: line = "Predictions: failed, using the word-pair model"
        }
        if let load = status.predictionLoadSeconds { line += " · loaded in \(String(format: "%.2f", load)) s" }
        if let last = status.predictionLastMs { line += " · last \(Int(last.rounded())) ms" }
        if let added = status.predictionFootprintMB { line += " · +\(Int(added.rounded())) MB" }
        // Temporary, with the counters in `KeyboardStatus`: read out by the owner when the Mac
        // cannot reach the phone.
        if let answers = status.predictionAnswers, let passes = status.stripPasses {
            line += " · answers \(answers), stale \(status.predictionStale ?? 0)"
            line += " · strip \(status.stripPassesWithPrediction ?? 0) of \(passes)"
        }
        if let free = status.predictionFreeMB { line += " · \(Int(free.rounded())) MB free" }
        return line
    }

    private var fullAccessDetail: String? {
        switch status.hasFullAccess {
        case true: nil
        case false: "Turn on Allow Full Access under Murmur in the keyboard list. The microphone needs it."
        case nil: "Not reported yet. If you've already opened the Murmur keyboard, turn on Allow Full Access."
        }
    }

    /// "Bark loaded in 1.8 s · warm-up 0.4 s", from the keyboard's last load.
    private var barkTimingLine: String? {
        guard let load = status.barkLoadSeconds else { return nil }
        let loaded = "Bark loaded in \(Self.format(seconds: load))"
        guard let warmup = status.barkWarmupSeconds else { return loaded }
        return "\(loaded) · warm-up \(Self.format(seconds: warmup))"
    }

    /// "Last release: 120 ms speech + 30 ms cleanup (Bark)", from the keyboard's last hold.
    private var releaseTimingLine: String? {
        guard let speech = status.lastReleaseEngineMs, let cleanup = status.lastReleaseCleanupMs else { return nil }
        let line = "Last release: \(speech) ms speech + \(cleanup) ms cleanup"
        return status.lastReleaseEngine.map { "\(line) (\($0))" } ?? line
    }

    private static func format(seconds: Double) -> String {
        seconds.formatted(.number.precision(.fractionLength(1))) + " s"
    }

    /// What the keyboard last said about Bark. Absent before the keyboard has run.
    private var keyboardEngineLine: String? {
        guard status.keyboardReported else { return nil }
        return switch status.keyboardBark {
        case .loading: "The keyboard is loading Bark."
        case .ready: "The keyboard has Bark ready."
        case .notDownloaded: "The keyboard is using Apple's transcriber until Bark is downloaded."
        case .stoppedLastTime: "The keyboard stopped last time while loading Bark."
        case .failed: "Bark failed to load in the keyboard."
        case .off, nil: "The keyboard is using Apple's transcriber."
        }
    }
}

/// A checklist row: a status glyph, a title, optional detail, and an action while undone.
private struct SetupRow<Action: View>: View {
    let title: String
    var detail: String?
    let isDone: Bool
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.base) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: DS.Icon.large))
                .foregroundStyle(isDone ? DS.Color.success : DS.Color.inkTertiary)
                .frame(width: DS.Phone.statusGlyphWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Text(title)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                if let detail {
                    Note(text: detail)
                }
            }
            Spacer(minLength: DS.Space.snug)
            if !isDone {
                action
                    .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(isDone ? "Done" : "Not done")
    }
}

private struct OpenSettingsButton: View {
    var body: some View {
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }
}
