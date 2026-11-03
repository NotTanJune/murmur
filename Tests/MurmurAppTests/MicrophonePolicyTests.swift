import CoreAudio
import Foundation
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

    @Test("A Bluetooth headset or any other default input is moved to the allowed mic")
    func correctsUnallowedDefault() {
        let devices = [airPods, builtIn, soloCast, iPhone]
        #expect(MicrophonePolicy.correction(forDefault: airPods.id, among: devices) == soloCast)
        #expect(MicrophonePolicy.correction(forDefault: builtIn.id, among: devices) == soloCast)
        #expect(MicrophonePolicy.correction(forDefault: nil, among: devices) == soloCast)
        #expect(MicrophonePolicy.correction(forDefault: atom.id, among: [atom, builtIn]) == builtIn)
    }

    @Test("An allowed default is left alone, and with no allowed mic nothing is changed")
    func leavesDefaultAlone() {
        #expect(MicrophonePolicy.correction(forDefault: soloCast.id, among: [airPods, soloCast]) == nil)
        #expect(MicrophonePolicy.correction(forDefault: builtIn.id, among: [airPods, builtIn]) == nil)
        #expect(MicrophonePolicy.correction(forDefault: airPods.id, among: [airPods, iPhone]) == nil)
    }

    @Test("Neither allowed microphone means no microphone, not the next best one")
    func refusesEverythingElse() {
        #expect(MicrophonePolicy.choose(from: [airPods, atom, iPhone, otherUSB]) == nil)
        #expect(MicrophonePolicy.choose(from: []) == nil)
    }
}

struct SystemInputSettingTests {
    @MainActor
    @Test("Keeping the Mac's input on the allowed mic is on by default and persists when turned off")
    func persistence() throws {
        let name = "murmur-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(Settings(defaults: defaults).keepSystemInput)
        Settings(defaults: defaults).keepSystemInput = false
        #expect(Settings(defaults: defaults).keepSystemInput == false)
    }
}
