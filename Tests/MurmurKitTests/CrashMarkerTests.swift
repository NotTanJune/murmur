import Foundation
import Testing
@testable import MurmurKit

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmurkit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func armedMarkerIsSeenByTheNextLaunch() throws {
    let directory = try scratch()
    #expect(CrashMarker(directory: directory).wasArmedAtLaunch == false)
    CrashMarker(directory: directory).arm()
    #expect(CrashMarker(directory: directory).wasArmedAtLaunch == true)
}

@Test func disarmedMarkerIsNotSeen() throws {
    let directory = try scratch()
    let marker = CrashMarker(directory: directory)
    marker.arm()
    marker.disarm()
    #expect(CrashMarker(directory: directory).wasArmedAtLaunch == false)
}

@Test func isArmedReadsTheFileNowWhileWasArmedAtLaunchStaysFixed() throws {
    let directory = try scratch()
    #expect(CrashMarker(directory: directory).isArmed == false)
    CrashMarker(directory: directory).arm()
    let atLaunch = CrashMarker(directory: directory)
    #expect(atLaunch.wasArmedAtLaunch)
    #expect(atLaunch.isArmed)
    // Another process (the app's "Try Bark again") clears the file.
    CrashMarker(directory: directory).disarm()
    #expect(atLaunch.wasArmedAtLaunch, "the launch snapshot does not change")
    #expect(atLaunch.isArmed == false, "the live check sees the file gone")
    atLaunch.arm()
    #expect(atLaunch.isArmed)
}
