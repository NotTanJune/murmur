import Foundation

/// Where a host keeps its files and settings.
///
/// The Mac app never configures it: unconfigured, storage is `Application Support/Murmur` and
/// settings come from the standard defaults, or from the suite named in `MURMUR_SETTINGS_DOMAIN`
/// (the `bench/` runner's seam). The iOS keyboard and its app call `configure` once, before
/// anything reads storage or `Settings.shared`, to point both at the shared app group.
public enum MurmurEnvironment {
    /// Call once, before anything reads storage or Settings. Unconfigured, both default to the Mac's values.
    ///
    /// A second call, or a call after something already read the root or the defaults, is a
    /// bug: `Settings.shared` and the stores pin the first answer, so the late value would
    /// apply to some readers and not others. It is logged as a fault and trips an assertion in
    /// debug builds.
    public static func configure(storageRoot: URL, defaults: UserDefaults) {
        let alreadyRead = wasRead.withLock { $0 }
        let problem: String? = state.withLock { current in
            let problem: String? = if current != nil {
                "MurmurEnvironment.configure called twice"
            } else if alreadyRead {
                "MurmurEnvironment.configure called after the storage root or defaults were read"
            } else {
                nil
            }
            current = Configuration(storageRoot: storageRoot, defaults: defaults)
            return problem
        }
        if let problem {
            Log.app.fault("\(problem, privacy: .public)")
            assertionFailure(problem)
        }
    }

    public static var storageRoot: URL {
        wasRead.withLock { $0 = true }
        return resolve(state.withLock { $0 }).storageRoot
    }

    public static var defaults: UserDefaults {
        wasRead.withLock { $0 = true }
        return resolve(state.withLock { $0 }).defaults
    }

    /// The root and defaults for a configuration, or the Mac's for none. Pure, so tests check
    /// both cases without configuring the process-global environment that `Settings.shared`
    /// and `RecordingStore.shared` pin on first use.
    static func resolve(_ configuration: Configuration?) -> (storageRoot: URL, defaults: UserDefaults) {
        (configuration?.storageRoot ?? macStorageRoot, configuration?.defaults ?? macDefaults)
    }

    /// `UserDefaults` is documented as thread-safe but not declared `Sendable`.
    struct Configuration: @unchecked Sendable {
        let storageRoot: URL
        let defaults: UserDefaults
    }

    private static let state = Locked<Configuration?>(nil)
    /// Whether `storageRoot` or `defaults` has been asked for, which `configure` must precede.
    private static let wasRead = Locked<Bool>(false)

    private static var macStorageRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
    }

    /// The `bench/` runner runs under `swift test`, whose process domain holds whatever earlier
    /// tests wrote, so it names a copy of the app's domain in `MURMUR_SETTINGS_DOMAIN` instead.
    /// Built once, so every unconfigured read returns the same instance.
    private nonisolated(unsafe) static let macDefaults: UserDefaults =
        ProcessInfo.processInfo.environment["MURMUR_SETTINGS_DOMAIN"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
}

/// A value behind a lock, readable from any thread.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
