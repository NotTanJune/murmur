import AVFoundation
import Foundation

/// Microphone capture with on-the-fly conversion to whatever format the speech engine wants.
///
/// The tap runs on real-time audio callbacks, so everything it touches lives behind
/// `nonisolated(unsafe)`. Callback-shared diagnostics are synchronized, and lifecycle
/// state is cleared only after the tap is removed and the engine is stopped.
final class AudioCapture: @unchecked Sendable {
    /// Replaced, not reused, when the input route changes. An idle engine keeps reporting
    /// the input format it saw when it was created, so switching the default microphone
    /// (say, built-in 44.1 kHz mono to a USB mic at 48 kHz stereo) leaves a stale tap format
    /// and every `start()` fails with -10868 until a fresh engine re-reads the hardware.
    private var engine = AVAudioEngine()
    private var configurationObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var converterInputFormat: AVAudioFormat?
    private nonisolated(unsafe) var outputFormat: AVAudioFormat?
    private var isRunning = false

    /// The microphone this engine records from (`MicrophonePolicy`), never the system default.
    private(set) var pinnedDevice: AudioInputDevice?
    /// When the pin was last applied. Pinning itself can make the engine post a
    /// configuration change; one that arrives right after is ours, not a real route change.
    private var lastPinnedAt = Date.distantPast
    /// A device was connected or removed mid-capture; re-pick once capture stops.
    private var needsRepin = false
    private var isObservingDevices = false
    /// Diagnostics only: record from this device instead of the policy's choice.
    var forcedDevice: AudioInputDevice?
    /// Main thread: a microphone was connected or removed while capture runs. The owner
    /// stops capture when it can; `stop()` then re-picks the device.
    var onRepinNeeded: (() -> Void)?
    /// Main thread, with the device now in use (nil when neither microphone is available).
    var onDeviceChange: ((AudioInputDevice?) -> Void)?

    enum CaptureError: LocalizedError {
        case noMicrophone
        case pinFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noMicrophone:
                "No microphone available: connect the HyperX SoloCast or open the MacBook's lid."
            case .pinFailed(let status):
                "Couldn't select the microphone (Core Audio error \(status))."
            }
        }
    }

    /// Called on the audio thread with each converted buffer.
    private nonisolated(unsafe) var onBuffer: (@Sendable (AudioChunk) -> Void)?
    /// Called on the audio thread with a 0…1 RMS level, for the HUD waveform.
    private nonisolated(unsafe) var onLevel: (@Sendable (Float) -> Void)?
    /// Called on the main thread when a route change stopped capture and it could not be
    /// restarted on the new device. Capture is already stopped when this runs.
    private var onInterruption: (@Sendable () -> Void)?

    /// Best-effort request for the smallest tap buffer. AVAudioEngine may choose a larger
    /// route-specific buffer, so latency diagnostics measure the actual callback size.
    private static let tapBufferSize: AVAudioFrameCount = 512

    /// Prepares the graph without starting microphone I/O. This moves graph allocation out
    /// of the first push-to-talk press while keeping the microphone inactive at idle.
    func prepare() {
        guard !isRunning else { return }
        observeConfigurationChanges()
        observeDevices()
        do { try ensurePinned() } catch {
            Log.audio.error("\(error.localizedDescription, privacy: .public)")
            return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        engine.prepare()
        Log.audio.info("audio graph prepared — native \(format.sampleRate)Hz")
    }

    func start(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onInterruption: @escaping @Sendable () -> Void = {}
    ) throws {
        guard !isRunning else { return }
        observeConfigurationChanges()
        observeDevices()
        try ensurePinned()

        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.onInterruption = onInterruption
        self.outputFormat = outputFormat

        let requestedAt = Date()
        let firstBuffer = OneShot()
        let levelGate = LevelGate()

        do {
            try startEngine(requestedAt: requestedAt, firstBuffer: firstBuffer, levelGate: levelGate)
        } catch {
            // -10868 (kAudioUnitErr_FormatNotSupported) is what a stale input format looks
            // like. The graph cannot be repaired in place; a new engine re-reads the device.
            Log.audio.error("audio engine start failed (\(error.localizedDescription)); rebuilding engine and retrying")
            rebuildEngine()
            do {
                try startEngine(requestedAt: requestedAt, firstBuffer: firstBuffer, levelGate: levelGate)
            } catch {
                converter = nil
                converterInputFormat = nil
                self.outputFormat = nil
                self.onBuffer = nil
                self.onLevel = nil
                self.onInterruption = nil
                throw error
            }
        }
        isRunning = true
    }

    /// Installs the tap and starts the current engine. On failure the tap is removed so the
    /// caller may retry against a fresh engine.
    private func startEngine(requestedAt: Date, firstBuffer: OneShot, levelGate: LevelGate) throws {
        guard let outputFormat else { return }
        // Never fall through to the system default input: no allowed microphone, no capture.
        guard pinnedDevice != nil else { throw CaptureError.noMicrophone }
        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)
        Log.audio.info(
            "start on \(self.pinnedDevice?.name ?? "?", privacy: .public): node out \(nativeFormat, privacy: .public) · node in \(input.inputFormat(forBus: 0), privacy: .public)"
        )

        converterInputFormat = nativeFormat
        converter = nativeFormat == outputFormat
            ? nil
            : AVAudioConverter(from: nativeFormat, to: outputFormat)

        input.removeTap(onBus: 0)
        // Passing the format reported before the engine starts is not reliable on macOS.
        // Voice-isolation and Bluetooth routes can change the input format between this
        // query and tap creation, and AVAudioEngine raises an Objective-C exception instead
        // of returning an error for that mismatch. nil asks the node for its live format.
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: nil) { [weak self] buffer, _ in
            self?.handle(
                buffer,
                requestedAt: requestedAt,
                firstBuffer: firstBuffer,
                levelGate: levelGate
            )
        }

        engine.prepare()
        let engineStartAt = Date()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        Log.performance.info(
            "audio engine start returned in \(Date().timeIntervalSince(engineStartAt), format: .fixed(precision: 3))s"
        )
        Log.audio.info("capture started — native \(nativeFormat.sampleRate)Hz → engine \(outputFormat.sampleRate)Hz")
    }

    /// Drops the current engine for a new one that reads the input device afresh, pinned to
    /// the microphone the policy picks now.
    private func rebuildEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        pinnedDevice = nil
        observeConfigurationChanges(reset: true)
        do { try ensurePinned() } catch {
            Log.audio.error("\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Points the engine's input at the policy's microphone if it isn't already. A fresh
    /// engine is used when switching, since a prepared one keeps its old device's format.
    private func ensurePinned() throws {
        guard let device = forcedDevice ?? MicrophonePolicy.current() else {
            if pinnedDevice != nil { onDeviceChange?(nil) }
            pinnedDevice = nil
            throw CaptureError.noMicrophone
        }
        guard device != pinnedDevice else { return }
        if pinnedDevice != nil {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine = AVAudioEngine()
            observeConfigurationChanges(reset: true)
        }
        guard let unit = engine.inputNode.audioUnit else { throw CaptureError.pinFailed(-1) }
        var id = device.id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw CaptureError.pinFailed(status) }

        // The node's device side now runs at the pinned mic's rate (the SoloCast is 48 kHz),
        // but its app side keeps the format from before the switch (44.1 kHz here). The input
        // node can't resample, so that mismatch fails `engine.start()` with -10868. Match
        // the app side to the hardware; `AudioCapture`'s converter takes it to 16 kHz.
        let hardware = engine.inputNode.inputFormat(forBus: 0)
        if hardware.sampleRate > 0,
           let client = AVAudioFormat(
               commonFormat: .pcmFormatFloat32,
               sampleRate: hardware.sampleRate,
               channels: hardware.channelCount,
               interleaved: false
           ) {
            var description = client.streamDescription.pointee
            let formatStatus = AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &description,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
            guard formatStatus == noErr else { throw CaptureError.pinFailed(formatStatus) }
        }

        pinnedDevice = device
        lastPinnedAt = Date()
        Log.audio.info("microphone pinned: \(device.name, privacy: .public)")
        onDeviceChange?(device)
    }

    /// Re-picks the microphone when one is connected or removed. Mid-capture the switch
    /// waits for the hold to end; if the device in use vanished, the configuration-change
    /// path below already moves capture to the fallback.
    private func observeDevices() {
        guard !isObservingDevices else { return }
        isObservingDevices = true
        MicrophonePolicy.observeDeviceChanges { [weak self] in
            guard let self else { return }
            guard MicrophonePolicy.current() != self.pinnedDevice else { return }
            if self.isRunning {
                self.needsRepin = true
                self.onRepinNeeded?()
            } else {
                Log.audio.info("microphone set changed while idle — re-pinning")
                self.rebuildEngine()
                self.engine.prepare()
            }
        }
    }

    /// AVAudioEngine posts this when the input or output route changes (device swap, sample
    /// rate change). While idle, swap in a fresh engine so the next press starts cleanly
    /// instead of failing against the old format. While recording, the engine has already
    /// stopped itself, so restart on the new device rather than leave the HUD showing a live
    /// meter over a dead microphone.
    private func observeConfigurationChanges(reset: Bool = false) {
        if reset, let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.isRunning {
                self.restartAfterRouteChange()
            } else if Date().timeIntervalSince(self.lastPinnedAt) < 1 {
                // Selecting the device reconfigured the engine; nothing to rebuild.
                return
            } else {
                Log.audio.info("audio configuration changed while idle — rebuilding engine")
                self.rebuildEngine()
            }
        }
    }

    /// Brings a live capture back after `AVAudioEngineConfigurationChange` stopped the engine.
    ///
    /// Restarts the *same* engine first. Rebuilding one re-pins the microphone, and that
    /// pin posts a configuration change of its own, which stopped the new engine and
    /// restarted the cycle every 2.4 s (278 times on 2026-10-31 after a Bluetooth headset
    /// changed state). Only when the pinned device is no longer the allowed one, or the
    /// restart fails, is the engine rebuilt on the fallback. A loop breaker stops capture
    /// outright if restarts keep coming, so a bad day costs one interruption, not a hot loop.
    private var restartTimes: [Date] = []
    private static let restartLimit = 6
    private static let restartWindow: TimeInterval = 30

    private func restartAfterRouteChange() {
        guard !engine.isRunning else { return }
        let now = Date()
        restartTimes = restartTimes.filter { now.timeIntervalSince($0) < Self.restartWindow } + [now]
        if restartTimes.count > Self.restartLimit {
            Log.audio.error("capture restarted \(self.restartTimes.count) times in \(Int(Self.restartWindow)) s — giving up")
            restartTimes.removeAll()
            let interrupted = onInterruption
            stop()
            interrupted?()
            return
        }

        if let pinnedDevice, pinnedDevice == MicrophonePolicy.current() {
            do {
                engine.prepare()
                try engine.start()
                Log.audio.notice("audio configuration changed during capture — restarted on \(pinnedDevice.name, privacy: .public)")
                return
            } catch {
                Log.audio.notice("restart on \(pinnedDevice.name, privacy: .public) failed (\(error.localizedDescription)); rebuilding")
            }
        } else {
            Log.audio.notice("audio route changed during capture — moving to the allowed device")
        }
        rebuildEngine()
        do {
            try startEngine(requestedAt: Date(), firstBuffer: OneShot(), levelGate: LevelGate())
        } catch {
            Log.audio.error("capture could not restart after route change: \(error.localizedDescription)")
            let interrupted = onInterruption
            stop()
            interrupted?()
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        converter = nil
        converterInputFormat = nil
        outputFormat = nil
        onBuffer = nil
        onLevel = nil
        onInterruption = nil
        Log.audio.info("capture stopped")
        if needsRepin {
            needsRepin = false
            rebuildEngine()
            engine.prepare()
        }
    }

    // MARK: - Audio thread

    private func handle(
        _ buffer: AVAudioPCMBuffer,
        requestedAt: Date,
        firstBuffer: OneShot,
        levelGate: LevelGate
    ) {
        if firstBuffer.take() {
            Log.audio.info(
                "first input buffer after \(Date().timeIntervalSince(requestedAt), format: .fixed(precision: 3))s — \(buffer.frameLength) frames at \(buffer.format.sampleRate, format: .fixed(precision: 0))Hz"
            )
        }
        if levelGate.shouldEmit(at: Date().timeIntervalSinceReferenceDate) {
            onLevel?(Self.rms(of: buffer))
        }

        guard let outputFormat else { return }

        // AVAudioEngine reuses the tap's buffer as soon as this returns, so the engine
        // must never see it directly — copy when no conversion would otherwise allocate.
        if buffer.format == outputFormat {
            converter = nil
            converterInputFormat = nil
            if let copy = Self.copy(buffer) {
                onBuffer?(AudioChunk(buffer: copy))
            }
            return
        }

        // The live tap format can differ from the pre-start query after a route change.
        // Rebuild the converter against the buffer we actually received.
        if converterInputFormat != buffer.format {
            converterInputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return }

        // Output frame count scales with the sample-rate ratio; round up so we never clip.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        // The input block runs synchronously inside `convert`, on this thread.
        nonisolated(unsafe) let input = buffer
        let consumed = Latch()
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            guard !consumed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }

        if let error {
            Log.audio.error("conversion failed: \(error.localizedDescription)")
            return
        }
        guard status != .error, converted.frameLength > 0 else { return }
        onBuffer?(AudioChunk(buffer: converted))
    }

    /// Deep-copies a tap buffer into storage we own.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }

        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else {
            return nil
        }

        return copy
    }

    /// Thread-safe one-shot flag for diagnostics shared by Core Audio callbacks.
    /// The tap can invoke callbacks on more than one audio thread when the route is
    /// starting, so the diagnostic latch cannot use the audio-thread-only `Latch`.
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !fired else { return false }
            fired = true
            return true
        }
    }

    /// One-shot flag. Only touched from the audio thread inside a synchronous call.
    private final class Latch: @unchecked Sendable {
        private var fired = false
        /// - Returns: the value *before* this call, then latches to `true`.
        func take() -> Bool {
            defer { fired = true }
            return fired
        }
    }

    /// The HUD renders at 30 fps, so scheduling more main-actor updates than that only
    /// competes with the transcription path when the tap buffer is small. Core Audio may
    /// reuse more than one callback thread, so the gate is synchronized.
    private final class LevelGate: @unchecked Sendable {
        private let lock = NSLock()
        private var lastEmission = -Double.infinity

        func shouldEmit(at time: TimeInterval) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard time - lastEmission >= 1.0 / 30.0 else { return false }
            lastEmission = time
            return true
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        let channels = max(1, Int(buffer.format.channelCount))
        guard frames > 0 else { return 0 }

        var sum: Float = 0
        if let channelData = buffer.floatChannelData {
            for channel in 0..<channels {
                for frame in 0..<frames {
                    let sample = channelData[channel][frame]
                    sum += sample * sample
                }
            }
        } else if let channelData = buffer.int16ChannelData {
            for channel in 0..<channels {
                for frame in 0..<frames {
                    let sample = Float(channelData[channel][frame]) / 32_768
                    sum += sample * sample
                }
            }
        } else if let channelData = buffer.int32ChannelData {
            for channel in 0..<channels {
                for frame in 0..<frames {
                    let sample = Float(channelData[channel][frame]) / 2_147_483_648
                    sum += sample * sample
                }
            }
        } else {
            return 0
        }

        let rms = (sum / Float(frames * channels)).squareRoot()

        // Map roughly -50…0 dBFS onto 0…1 so quiet speech still moves the meter.
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }
}
