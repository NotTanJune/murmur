import CoreAudio
import Foundation

/// One Core Audio device that can record.
struct AudioInputDevice: Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
}

/// Which microphone Murmur records from.
///
/// Never the system default input. Murmur pins its own capture to the HyperX SoloCast when
/// it is connected and to the Mac's built-in microphone otherwise — nothing else, ever. In
/// particular a Bluetooth headset or speaker never becomes the input: opening a Bluetooth
/// mic drops the headset into low-quality call mode for as long as it stays open, and the
/// system default follows whatever connected last. The pin applies to Murmur's capture
/// only; other apps keep the system default.
enum MicrophonePolicy {
    /// External microphones to prefer, by name, in order. First connected match wins.
    static let preferredNames = ["HyperX SoloCast"]

    /// Picks from a device list. Pure, so the rule is testable without hardware.
    static func choose(from devices: [AudioInputDevice]) -> AudioInputDevice? {
        for name in preferredNames {
            if let match = devices.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                return match
            }
        }
        return devices.first(where: \.isBuiltIn)
    }

    /// The microphone to use right now, or nil when neither is available (a closed lid with
    /// the SoloCast unplugged).
    static func current() -> AudioInputDevice? {
        choose(from: inputDevices())
    }

    /// Every device with at least one input stream.
    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInput(id), let name = name(of: id) else { return nil }
            return AudioInputDevice(id: id, name: name, transport: transport(of: id))
        }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func transport(of id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        return transport
    }

    /// Calls `onChange` on the main queue whenever a device is connected or removed.
    static func observeDeviceChanges(_ onChange: @escaping @Sendable () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main
        ) { _, _ in onChange() }
    }
}
