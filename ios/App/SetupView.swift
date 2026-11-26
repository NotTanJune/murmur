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
    /// The strip's language model as the keyboard last reported it
    /// (`SmartPredictions.State`); nil until it has.
    private(set) var predictionState: String?
    /// Bark stopped the keyboard last time, and nothing live is using the marker.
    private(set) var markerArmed = false
    private(set) var isShared = PhoneEnvironment.isShared

    /// How long after its last report a keyboard still counts as loading Bark. The keyboard
    /// reports when a load starts and when it ends, and nothing in between, so a load that
    /// outlasts this with the marker still armed is taken to have killed it. Bark's first load
    /// after an install compiles for the Neural Engine and has taken 84 to 106 s on the owner's
    /// phone, so the limit is well past that.
    static let loadingStaleAfter: TimeInterval = 300

    func refresh() {
        microphone = AVAudioApplication.shared.recordPermission
        speech = SFSpeechRecognizer.authorizationStatus()
        let reported = KeyboardStatus.read()
        predictionState = reported?.predictionState
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

/// The first tab: what the keyboard needs, each with a check mark once it is in place and the
/// one-tap way to it until then.
struct SetupView: View {
    @Environment(\.scenePhase) private var phase
    @State private var status = SetupStatus()

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
                    detail: status.keyboardAdded ? nil : "Settings, General, Keyboard, Keyboards, Add New Keyboard, Murmur.",
                    isDone: status.keyboardAdded
                ) {
                    OpenSettingsButton()
                }
                SetupRow(
                    title: "Full Access",
                    detail: fullAccessDetail,
                    isDone: status.hasFullAccess == true
                ) {
                    OpenSettingsButton()
                }
                SetupRow(
                    title: "Predictions",
                    detail: predictionDetail,
                    isDone: status.predictionState == "ready"
                ) {
                    if status.predictionState == "stoppedLastTime" {
                        Button("Try again") {
                            CrashMarker.typingModel.disarm()
                            CrashMarker.typingModelStrike.disarm()
                        }
                    }
                }
            }

            Card(title: "Dictation") {
                BarkModelRow()
                if let line = barkLine {
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
        .onAppear { status.refresh() }
        .onChange(of: phase) { _, now in
            if now == .active { status.refresh() }
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

    /// Why the Predictions row has no check mark. Nil when it has one: the model loaded and
    /// answered in the keyboard's process (`SmartPredictions.State.ready`).
    private var predictionDetail: String? {
        switch status.predictionState {
        case "ready": nil
        case "loading": "Loading…"
        case "waiting", nil: "Loads when the Murmur keyboard opens."
        case "off": "Off in Settings."
        case "missing": "This build has no model."
        case "lowMemory": "Not enough memory just now. It tries again by itself."
        case "stoppedLastTime": "Stopped while loading, twice. It tries again by itself in half an hour."
        default: "Did not load."
        }
    }

    private var fullAccessDetail: String? {
        switch status.hasFullAccess {
        case true: nil
        case false: "Turn on Allow Full Access under Murmur in the keyboard list. The microphone needs it."
        case nil: "Not reported yet. If you've already opened the Murmur keyboard, turn on Allow Full Access."
        }
    }

    /// What Bark is doing in the keyboard, said only while it is not simply ready. A model
    /// that is not downloaded says so in its own row, and one that stopped the keyboard has
    /// the card at the top.
    private var barkLine: String? {
        switch status.keyboardBark {
        case .loading: "Loading in the keyboard. Apple's transcriber stands in until it is ready."
        case .failed: "Bark did not load in the keyboard. Apple's transcriber is standing in."
        case .ready, .notDownloaded, .stoppedLastTime, .off, nil: nil
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
