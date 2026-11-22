import AVFoundation
import MurmurKit
import SwiftUI

/// Plays one history run's recording at a time from `RecordingStore`.
@MainActor @Observable
final class RunAudioPlayer {
    static let shared = RunAudioPlayer()

    /// The run whose audio is playing now.
    private(set) var playingID: UUID?
    private(set) var failure: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var finishObserver: Finisher?

    func toggle(_ run: DictationRun) {
        if playingID == run.id {
            stop()
        } else {
            play(run)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        finishObserver = nil
        playingID = nil
        // Hands the audio route back, so music that was playing underneath resumes.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func play(_ run: DictationRun) {
        stop()
        failure = nil
        let url = RecordingStore.shared.url(for: run.id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            failure = "This recording is no longer on the iPhone."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // Playback only: the keyboard owns the microphone session when it records.
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let next = try AVAudioPlayer(contentsOf: url)
            let finisher = Finisher { [weak self] in
                Task { @MainActor in
                    guard self?.playingID == run.id else { return }
                    self?.stop()
                }
            }
            next.delegate = finisher
            finishObserver = finisher
            guard next.play() else {
                failure = "The recording could not be played."
                return
            }
            player = next
            playingID = run.id
        } catch {
            failure = error.localizedDescription
        }
    }

    /// `AVAudioPlayerDelegate` is an Objective-C protocol, so the callback is its own object.
    private final class Finisher: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        private let onFinish: @Sendable () -> Void

        init(onFinish: @escaping @Sendable () -> Void) {
            self.onFinish = onFinish
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            onFinish()
        }
    }
}
