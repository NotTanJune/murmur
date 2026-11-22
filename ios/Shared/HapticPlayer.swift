import CoreHaptics
import Foundation
import OSLog

// TEMPORARY: part of the Haptic Lab (see `HapticPattern.swift`).

/// Plays `HapticPattern`s through one lazily made `CHHapticEngine`. Main actor only. Errors are
/// logged and returned, never thrown into the caller's flow, so a keyboard can fall back.
@MainActor
final class HapticPlayer {
    private static let log = Logger(subsystem: "ai.pivotstudio.murmur", category: "speech")

    private var engine: CHHapticEngine?
    private var isRunning = false
    private var isStarting = false

    static var isSupported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    /// Starts the engine ahead of a play, without waiting for it.
    func prepare() {
        guard !isRunning, !isStarting, let engine = makeEngineIfNeeded() else { return }
        isStarting = true
        engine.start { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isStarting = false
                if let error {
                    Self.log.error("haptic lab: engine start failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    self.isRunning = true
                }
            }
        }
    }

    /// Plays `pattern` now. Returns whether Core Haptics accepted it; an error is logged.
    @discardableResult
    func play(_ pattern: HapticPattern) -> Bool {
        do {
            guard let engine = makeEngineIfNeeded() else { return false }
            if !isRunning {
                try engine.start()
                isRunning = true
            }
            let player = try engine.makePlayer(with: try pattern.coreHapticsPattern())
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            Self.log.error("haptic lab: playback failed: \(error.localizedDescription, privacy: .public)")
            isRunning = false
            return false
        }
    }

    private func makeEngineIfNeeded() -> CHHapticEngine? {
        if let engine { return engine }
        guard Self.isSupported else {
            Self.log.error("haptic lab: this device reports no Core Haptics support")
            return nil
        }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            engine.stoppedHandler = { [weak self] reason in
                Task { @MainActor in
                    Self.log.info("haptic lab: engine stopped (reason \(reason.rawValue))")
                    self?.isRunning = false
                }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    Self.log.info("haptic lab: engine reset, restarting")
                    self?.isRunning = false
                    self?.prepare()
                }
            }
            self.engine = engine
            return engine
        } catch {
            Self.log.error("haptic lab: engine creation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
