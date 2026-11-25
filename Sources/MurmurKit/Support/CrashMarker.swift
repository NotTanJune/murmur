import Foundation

/// Remembers that Bark was loading when the keyboard last died.
///
/// iOS kills a keyboard extension that uses too much memory, with no callback. If Bark is what
/// pushed it over, loading Bark again on the next appearance would kill it again, every time,
/// and the user could not type. So the keyboard arms this before loading Bark and disarms it
/// after Bark's first successful hold; a marker still armed at launch means the last load died,
/// and the keyboard runs Apple's transcriber instead.
public struct CrashMarker: Sendable {
    private let url: URL
    /// Read once, at creation: the state the previous process left behind.
    public let wasArmedAtLaunch: Bool

    /// `name` is the marker's file name. Bark's is the default; the keyboard's language model
    /// keeps a marker of its own under another name, with the same rules.
    public init(directory: URL, name: String = "bark-loading") {
        url = directory.appendingPathComponent(name)
        wasArmedAtLaunch = FileManager.default.fileExists(atPath: url.path)
    }

    /// Whether the marker file exists right now. `wasArmedAtLaunch` is what the last process
    /// left; this is the live answer, so a long-lived keyboard can see that the app's "Try Bark
    /// again" button cleared it since.
    public var isArmed: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func arm() {
        try? Data().write(to: url, options: .atomic)
    }

    public func disarm() {
        try? FileManager.default.removeItem(at: url)
    }
}
