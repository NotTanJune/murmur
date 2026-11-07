import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures microphone audio and converts it on the fly to the format the speech engine asked for.
///
/// Records through a standalone input-only AUHAL unit pinned to the policy's microphone,
/// **not** `AVAudioEngine`. The engine's input node follows the system default input: a
/// device set on its audio unit is switched back to the default aggregate within about
/// 50 ms whenever the default is another device. On 2026-11-03 a Bluetooth headset (16 kHz
/// mono) was the default, the SoloCast pin was reverted between `prepare()` and `start()`,
/// and `installTapOnBus` raised an Objective-C exception for the 48 kHz/16 kHz mismatch.
/// AppKit swallowed it inside a main-actor task, which left Swift's executor tracking
/// pointing at dead stack, and the next SwiftUI tooltip hit-test crashed the app at launch.
///
/// The input callback runs on Core Audio's real-time thread, so everything it touches lives
/// behind `nonisolated(unsafe)`. Callback-shared diagnostics are synchronized, and lifecycle
/// state is cleared only after the unit has stopped.
final class AudioCapture: @unchecked Sendable {
    /// The AUHAL unit, initialized and pinned while a microphone is available. Replaced, not
    /// reconfigured, when the device or its format changes.
    private nonisolated(unsafe) var unit: AudioUnit?
    /// The unit's app-side format: Float32, deinterleaved, at the device's own rate and
    /// channel count. AUHAL can't resample input; `converter` takes it to `outputFormat`.
    private var deviceFormat: AVAudioFormat?
    /// Reused by every callback for `AudioUnitRender`. `handle` copies or converts out of it.
    private nonisolated(unsafe) var renderBuffer: AVAudioPCMBuffer?
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var converterInputFormat: AVAudioFormat?
    private nonisolated(unsafe) var outputFormat: AVAudioFormat?
    /// Diagnostics for the capture in progress, read by the input callback.
    private nonisolated(unsafe) var session: Session?
    /// Main thread only: true from a successful `start` until `stop`.
    private var isRunning = false

    /// The microphone this unit records from (`MicrophonePolicy`), never the system default.
    private(set) var pinnedDevice: AudioInputDevice?
    /// Listeners on the pinned device for removal and sample-rate changes.
    private var deviceListeners: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
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
        case startFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noMicrophone:
                "No microphone available: connect the HyperX SoloCast or open the MacBook's lid."
            case .pinFailed(let status):
                "Couldn't select the microphone (Core Audio error \(status))."
            case .startFailed(let status):
                "Couldn't start the microphone (Core Audio error \(status))."
            }
        }
    }

    private struct Session {
        let requestedAt: Date
        let firstBuffer: OneShot
        let levelGate: LevelGate
    }

    /// Audio thread: receives each converted buffer.
    private nonisolated(unsafe) var onBuffer: (@Sendable (AudioChunk) -> Void)?
    /// Audio thread: receives a 0 to 1 level for the HUD waveform. Both closures are dropped when capture stops.
    private nonisolated(unsafe) var onLevel: (@Sendable (Float) -> Void)?
    /// Called on the main thread when a route change stopped capture and it could not be
    /// restarted on the new device. Capture is already stopped when this runs.
    private var onInterruption: (@Sendable () -> Void)?

    deinit {
        disposeUnit()
    }

    /// Pins and initializes the unit without starting microphone I/O. This moves device
    /// setup out of the first push-to-talk press while keeping the microphone inactive at idle.
    func prepare() {
        guard !isRunning else { return }
        observeDevices()
        do { try ensurePinned() } catch {
            Log.audio.error("\(error.localizedDescription, privacy: .public)")
            return
        }
        Log.audio.info("audio unit prepared — native \(self.deviceFormat?.sampleRate ?? 0)Hz")
    }

    func start(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onInterruption: @escaping @Sendable () -> Void = {}
    ) throws {
        guard !isRunning else { return }
        observeDevices()
        try ensurePinned()

        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.onInterruption = onInterruption
        self.outputFormat = outputFormat
        session = Session(requestedAt: Date(), firstBuffer: OneShot(), levelGate: LevelGate())

        do {
            try startUnit()
        } catch {
            // A device that changed format or vanished since it was pinned. A fresh unit
            // re-reads it, or moves to whichever allowed microphone is left.
            Log.audio.error("audio unit start failed (\(error.localizedDescription)); re-pinning and retrying")
            do {
                try repin()
                try startUnit()
            } catch {
                clearCaptureState()
                throw error
            }
        }
        isRunning = true
    }

    /// Starts the current unit, converting from its device format to `outputFormat`.
    private func startUnit() throws {
        guard let outputFormat else { return }
        // Never fall through to the system default input: no allowed microphone, no capture.
        guard let unit, let deviceFormat, pinnedDevice != nil else { throw CaptureError.noMicrophone }
        Log.audio.info(
            "start on \(self.pinnedDevice?.name ?? "?", privacy: .public): device \(deviceFormat, privacy: .public)"
        )

        converterInputFormat = deviceFormat
        converter = deviceFormat == outputFormat
            ? nil
            : AVAudioConverter(from: deviceFormat, to: outputFormat)

        let startAt = Date()
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw CaptureError.startFailed(status) }
        Log.performance.info(
            "audio unit start returned in \(Date().timeIntervalSince(startAt), format: .fixed(precision: 3))s"
        )
        Log.audio.info("capture started — native \(deviceFormat.sampleRate)Hz → engine \(outputFormat.sampleRate)Hz")
    }

    /// Points capture at the policy's microphone, building a unit for it if there isn't one.
    private func ensurePinned() throws {
        guard let device = forcedDevice ?? MicrophonePolicy.current() else {
            disposeUnit()
            if pinnedDevice != nil { onDeviceChange?(nil) }
            pinnedDevice = nil
            throw CaptureError.noMicrophone
        }
        if device == pinnedDevice, unit != nil { return }
        disposeUnit()
        try makeUnit(for: device)
        observe(device)

        let changed = device != pinnedDevice
        pinnedDevice = device
        Log.audio.info("microphone pinned: \(device.name, privacy: .public)")
        if changed { onDeviceChange?(device) }
    }

    /// Drops the current unit and pins afresh to the microphone the policy picks now.
    private func repin() throws {
        disposeUnit()
        pinnedDevice = nil
        try ensurePinned()
    }

    /// An input-only AUHAL on `device`. Its device is set once and nothing else moves it,
    /// unlike `AVAudioEngine`'s input node.
    private func makeUnit(for device: AudioInputDevice) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptureError.pinFailed(-1)
        }
        var created: AudioUnit?
        var status = AudioComponentInstanceNew(component, &created)
        guard status == noErr, let created else { throw CaptureError.pinFailed(status) }

        do {
            // Element 1 is the input side, element 0 the output side. Input only.
            var enable: UInt32 = 1
            var disable: UInt32 = 0
            try check(AudioUnitSetProperty(
                created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                &enable, UInt32(MemoryLayout<UInt32>.size)
            ))
            try check(AudioUnitSetProperty(
                created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                &disable, UInt32(MemoryLayout<UInt32>.size)
            ))

            var id = device.id
            try check(AudioUnitSetProperty(
                created, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            ))

            // The app side must run at the device's rate: AUHAL converts sample format and
            // layout on input but not sample rate.
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(
                created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size
            ))
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32,
                      sampleRate: hardware.mSampleRate,
                      channels: hardware.mChannelsPerFrame,
                      interleaved: false
                  )
            else { throw CaptureError.pinFailed(kAudioUnitErr_FormatNotSupported) }
            var client = format.streamDescription.pointee
            try check(AudioUnitSetProperty(
                created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ))

            var callback = AURenderCallbackStruct(
                inputProc: Self.inputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check(AudioUnitSetProperty(
                created, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ))

            status = AudioUnitInitialize(created)
            try check(status)

            var maxFrames: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitGetProperty(
                created, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                &maxFrames, &size
            ))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(maxFrames, 4096)) else {
                throw CaptureError.pinFailed(kAudio_MemFullError)
            }

            renderBuffer = buffer
            deviceFormat = format
            unit = created
        } catch {
            AudioUnitUninitialize(created)
            AudioComponentInstanceDispose(created)
            throw error
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw CaptureError.pinFailed(status) }
    }

    /// Stops and releases the unit. `AudioOutputUnitStop` returns after the last callback.
    private func disposeUnit() {
        removeDeviceListeners()
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        renderBuffer = nil
        deviceFormat = nil
    }

    /// Re-picks the microphone when one is connected or removed. Mid-capture the switch
    /// waits for the hold to end; if the device in use vanished, its own listener below
    /// already moves capture to the fallback.
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
                do { try self.repin() } catch {
                    Log.audio.error("\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Watches the pinned device for removal and for a sample-rate change, either of which
    /// leaves the unit's app-side format wrong. While idle, the unit is rebuilt so the next
    /// press starts cleanly; while recording, capture restarts on whatever is allowed now.
    private func observe(_ device: AudioInputDevice) {
        removeDeviceListeners()
        let selectors = [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.deviceChanged(device)
            }
            if AudioObjectAddPropertyListenerBlock(device.id, &address, .main, listener) == noErr {
                deviceListeners.append((device.id, address, listener))
            }
        }
    }

    private func removeDeviceListeners() {
        for (id, address, listener) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, listener)
        }
        deviceListeners.removeAll()
    }

    private func deviceChanged(_ device: AudioInputDevice) {
        guard device == pinnedDevice, let deviceFormat else { return }
        if Self.isAlive(device.id), Self.nominalRate(of: device.id) == deviceFormat.sampleRate {
            return
        }
        if isRunning {
            restartAfterRouteChange()
        } else {
            Log.audio.info("microphone format or presence changed while idle — re-pinning")
            do { try repin() } catch {
                Log.audio.error("\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Brings a live capture back after the pinned device changed rate or vanished, on the
    /// same device if it is still the allowed one, otherwise on the fallback. A loop breaker
    /// stops capture outright if restarts keep coming, so a bad day costs one interruption,
    /// not a hot loop (an engine-based version once restarted 278 times on 2026-10-31).
    private var restartTimes: [Date] = []
    private static let restartLimit = 6
    private static let restartWindow: TimeInterval = 30

    private func restartAfterRouteChange() {
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

        do {
            try repin()
            session = Session(requestedAt: Date(), firstBuffer: OneShot(), levelGate: LevelGate())
            try startUnit()
            Log.audio.notice("microphone changed during capture — restarted on \(self.pinnedDevice?.name ?? "?", privacy: .public)")
        } catch {
            Log.audio.error("capture could not restart after route change: \(error.localizedDescription)")
            let interrupted = onInterruption
            stop()
            interrupted?()
        }
    }

    /// Stops capture and releases per-capture state. Does nothing when idle.
    func stop() {
        guard isRunning else { return }
        if let unit { AudioOutputUnitStop(unit) }
        isRunning = false
        clearCaptureState()
        Log.audio.info("capture stopped")
        if needsRepin {
            needsRepin = false
            do { try repin() } catch {
                Log.audio.error("\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func clearCaptureState() {
        converter = nil
        converterInputFormat = nil
        outputFormat = nil
        session = nil
        onBuffer = nil
        onLevel = nil
        onInterruption = nil
    }

    private static func isAlive(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    private static func nominalRate(of id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return rate
    }

    // MARK: - Input callback

    private static let inputCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
        Unmanaged<AudioCapture>.fromOpaque(refCon).takeUnretainedValue()
            .render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
    }

    /// Pulls this cycle's input from the unit into the reused buffer, then hands it on.
    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard let unit, let buffer = renderBuffer, let session,
              frames <= buffer.frameCapacity
        else { return noErr }
        // Setting frameLength also resets each AudioBuffer's byte size for the render.
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }
        handle(
            buffer,
            requestedAt: session.requestedAt,
            firstBuffer: session.firstBuffer,
            levelGate: session.levelGate
        )
        return noErr
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
            onLevel?(Self.level(of: buffer))
        }

        guard let outputFormat else { return }

        // The render buffer is reused by the next callback, so the speech engine must
        // never see it directly — copy when no conversion would otherwise allocate.
        if buffer.format == outputFormat {
            converter = nil
            converterInputFormat = nil
            if let copy = Self.deepCopy(buffer) {
                onBuffer?(AudioChunk(buffer: copy))
            }
            return
        }

        // Rebuild the converter if the buffer's format no longer matches the one it was
        // made for, so a stale converter never sees the wrong rate.
        if converterInputFormat != buffer.format {
            converterInputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return }

        // Capacity covers the rate ratio rounded up, plus a margin so resampling never clips.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        // The converter persists across callbacks, so the input block must never signal end of
        // stream; it supplies the render buffer once and then reports no data for now.
        let supplied = SuppliedFlag()
        nonisolated(unsafe) let input = buffer
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if supplied.testAndSet() {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError {
            Log.audio.error("audio conversion failed: \(conversionError.localizedDescription, privacy: .public)")
            return
        }
        guard status != .error, converted.frameLength > 0 else { return }
        onBuffer?(AudioChunk(buffer: converted))
    }

    /// Deep-copies a rendered buffer into storage we own.
    private static func deepCopy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard source.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength)
        else { return nil }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard from.count == to.count else { return nil }
        for index in 0..<from.count {
            guard let sourceData = from[index].mData, let destinationData = to[index].mData else { return nil }
            let bytes = min(Int(from[index].mDataByteSize), Int(to[index].mDataByteSize))
            memcpy(destinationData, sourceData, bytes)
            to[index].mDataByteSize = UInt32(bytes)
        }
        return copy
    }

    /// Thread-safe one-shot flag for diagnostics shared by Core Audio callbacks.
    /// Core Audio can invoke callbacks on more than one audio thread when the route is
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

    /// Remembers whether the converter's input block already supplied its buffer. Touched only
    /// from the audio thread inside one synchronous `convert` call, so it needs no lock.
    private final class SuppliedFlag: @unchecked Sendable {
        private var value = false

        /// Returns the previous value and leaves the flag set.
        func testAndSet() -> Bool {
            let previous = value
            value = true
            return previous
        }
    }

    /// The HUD renders at 30 fps, so scheduling more main-actor updates than that only
    /// competes with the transcription path when the I/O buffer is small. Core Audio may
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

    /// Maps a buffer's RMS onto 0...1 for the level meter.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
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

        // A -50...0 dBFS window lets quiet speech still move the meter.
        let decibels = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (decibels + 50) / 50))
    }
}
