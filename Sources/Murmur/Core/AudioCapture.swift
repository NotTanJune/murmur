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
        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)

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

    /// Drops the current engine for a new one that reads the input device afresh.
    private func rebuildEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        observeConfigurationChanges(reset: true)
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
            } else {
                Log.audio.info("audio configuration changed while idle — rebuilding engine")
                self.rebuildEngine()
            }
        }
    }

    /// Moves a live capture onto a fresh engine. The callbacks and output format carry over,
    /// so the speech engine keeps receiving the same format; only the converter is rebuilt.
    private func restartAfterRouteChange() {
        guard !engine.isRunning else { return }
        Log.audio.notice("audio route changed during capture — restarting on the new device")
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
