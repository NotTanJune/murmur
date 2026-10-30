import Foundation

/// The app's handle on S1-mini, which runs in a helper process (`S1MiniServer`).
///
/// `load` starts the helper (the same executable with `--s1-server`) and waits until it
/// reports ready; `unload` ends it, which returns all of its memory to the system. Nothing
/// MLX ever runs in the app process itself.
actor S1MiniEngine {
    static let shared = S1MiniEngine()

    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var isReady = false
    private var loading: Task<Void, Error>?
    private var startup: CheckedContinuation<Void, Error>?
    private var onPhase: (@Sendable (S1MiniModelStore.Phase?) -> Void)?
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var nextID = 0

    var isLoaded: Bool { isReady }

    /// Waits for a load in progress. True when the helper is ready to clean.
    func waitUntilReady() async -> Bool {
        if isReady { return true }
        if let loading { _ = try? await loading.value }
        return isReady
    }

    /// Starts the helper, which installs the model if needed and loads it. Concurrent
    /// callers share one start.
    func load(phase: @escaping @Sendable (S1MiniModelStore.Phase?) -> Void) async throws {
        if isReady { return }
        if let loading { return try await loading.value }
        let task = Task { try await self.launch(phase: phase) }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    /// Ends the helper and with it every byte S1-mini held.
    func unload() {
        guard loading == nil, let process else { return }
        try? input?.close()
        process.terminate()
        Log.speech.info("S1-mini: helper stopped to free memory")
    }

    /// Cleans one transcript. Throws if the helper isn't ready; the formatter falls back to
    /// the rule pass.
    func clean(_ text: String, profile: CleanupProfile) async throws -> String {
        guard isReady, let input else { throw S1MiniError.notLoaded }
        nextID += 1
        let id = nextID
        guard var line = try? JSONEncoder().encode(S1MiniMessage(profile: profile.rawValue, id: id, text: text)) else {
            throw S1MiniError.notLoaded
        }
        line.append(0x0A)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                pending[id] = continuation
                do {
                    try input.write(contentsOf: line)
                } catch {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    // MARK: - Helper process

    private func launch(phase: @escaping @Sendable (S1MiniModelStore.Phase?) -> Void) async throws {
        guard let executable = Bundle.main.executableURL else { throw S1MiniError.helperUnavailable }
        let started = Date()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--s1-server"]
        let toHelper = Pipe()
        let fromHelper = Pipe()
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        process.standardError = FileHandle.nullDevice
        try process.run()

        self.process = process
        input = toHelper.fileHandleForWriting
        onPhase = phase
        let output = fromHelper.fileHandleForReading
        reader = Task.detached { [weak self] in
            do {
                for try await line in output.bytes.lines {
                    await self?.receive(line)
                }
            } catch {}
            await self?.helperExited()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startup = continuation
        }
        Log.speech.info(
            "S1-mini: helper ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s (pid \(process.processIdentifier))"
        )
    }

    private func receive(_ line: String) {
        guard let message = try? JSONDecoder().decode(S1MiniMessage.self, from: Data(line.utf8)) else { return }
        if let id = message.id {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let text = message.text {
                continuation.resume(returning: text)
            } else {
                continuation.resume(throwing: S1MiniError.helper(message.error ?? "no reply"))
            }
        } else if let phase = message.phase {
            onPhase?(phase == "downloading" ? .downloading : phase == "converting" ? .converting : nil)
        } else if message.ready == true {
            isReady = true
            startup?.resume()
            startup = nil
        } else if let fatal = message.fatal {
            startup?.resume(throwing: S1MiniError.helper(fatal))
            startup = nil
        }
    }

    private func abandon(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// The helper exited: stopped on idle, crashed, or failed to start. Everything waiting on
    /// it fails over to the rule pass; the next press starts a fresh one.
    private func helperExited() {
        isReady = false
        process = nil
        input = nil
        reader = nil
        onPhase = nil
        startup?.resume(throwing: S1MiniError.helper("the helper exited during startup"))
        startup = nil
        for continuation in pending.values {
            continuation.resume(throwing: S1MiniError.helper("the helper exited"))
        }
        pending.removeAll()
    }
}

enum S1MiniError: LocalizedError {
    case notLoaded
    case tooLong(Int)
    case helperUnavailable
    case helper(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded: "S1-mini is not loaded"
        case .tooLong(let tokens): "transcript is \(tokens) tokens, over S1-mini's single-pass limit"
        case .helperUnavailable: "couldn't find the app executable to start the S1-mini helper"
        case .helper(let message): message
        }
    }
}
