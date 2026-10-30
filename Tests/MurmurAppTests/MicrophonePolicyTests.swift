import CoreAudio
import Testing
@testable import Murmur

@Suite struct MicrophonePolicyTests {
    private let soloCast = AudioInputDevice(id: 10, name: "HyperX SoloCast", transport: kAudioDeviceTransportTypeUSB)
    private let builtIn = AudioInputDevice(id: 11, name: "MacBook Air Microphone", transport: kAudioDeviceTransportTypeBuiltIn)
    private let airPods = AudioInputDevice(id: 12, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
    private let atom = AudioInputDevice(id: 13, name: "Atom", transport: kAudioDeviceTransportTypeBluetooth)
    private let iPhone = AudioInputDevice(id: 14, name: "Tanmay's iPhone Microphone", transport: kAudioDeviceTransportTypeContinuityCaptureWireless)
    private let otherUSB = AudioInputDevice(id: 15, name: "USB Audio", transport: kAudioDeviceTransportTypeUSB)

    @Test("The SoloCast wins whenever it is connected, whatever else is")
    func prefersSoloCast() {
        #expect(MicrophonePolicy.choose(from: [airPods, builtIn, soloCast, iPhone]) == soloCast)
        #expect(MicrophonePolicy.choose(from: [soloCast]) == soloCast)
    }

    @Test("Without the SoloCast it is the built-in mic, never Bluetooth, iPhone or another USB device")
    func fallsBackToBuiltIn() {
        #expect(MicrophonePolicy.choose(from: [airPods, atom, iPhone, otherUSB, builtIn]) == builtIn)
    }

    @Test("Neither allowed microphone means no microphone, not the next best one")
    func refusesEverythingElse() {
        #expect(MicrophonePolicy.choose(from: [airPods, atom, iPhone, otherUSB]) == nil)
        #expect(MicrophonePolicy.choose(from: []) == nil)
    }
}
