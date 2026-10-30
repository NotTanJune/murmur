import Darwin
import Foundation

/// One line of the helper protocol, in either direction. Every field is optional so one
/// type covers startup progress, readiness, requests and replies.
struct S1MiniMessage: Codable, Sendable {
    // Helper → app, during startup.
    var phase: String?
    var ready: Bool?
    var fatal: String?
    // App → helper.
    var profile: String?
    // Both: a request and its reply share an id.
    var id: Int?
    var text: String?
    var error: String?
}

/// `Murmur --s1-server`: S1-mini in a process of its own.
///
/// MLX and the tokenizer leave 40–100 MB of fragmented heap behind when the model is
/// released in-process, and it grows with every load (measured on an M2). A process that
/// exits returns everything, so the app starts this helper at the press that needs it and
/// ends it after the idle timeout. Line-delimited JSON on stdin and stdout; stdout carries
/// nothing else. Exits when stdin closes, so it never outlives the app.
enum S1MiniServer {
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        Task.detached { await serve() }
        dispatchMain()
    }

    private static func serve() async {
        let runtime = S1MiniRuntime.shared
        do {
            try await runtime.load { phase in
                let name = switch phase {
                case .downloading: "downloading"
                case .converting: "converting"
                case nil: "loading"
                }
                send(S1MiniMessage(phase: name))
            }
        } catch {
            send(S1MiniMessage(fatal: error.localizedDescription))
            exit(EXIT_FAILURE)
        }
        send(S1MiniMessage(ready: true))

        let decoder = JSONDecoder()
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let request = try? decoder.decode(S1MiniMessage.self, from: Data(line.utf8)),
                      let id = request.id, let text = request.text,
                      let profile = request.profile.flatMap(CleanupProfile.init(rawValue:))
                else { continue }
                do {
                    send(S1MiniMessage(id: id, text: try await runtime.clean(text, profile: profile)))
                } catch {
                    send(S1MiniMessage(id: id, error: error.localizedDescription))
                }
            }
        } catch {}
        exit(EXIT_SUCCESS)
    }

    private static let output = NSLock()

    private static func send(_ message: S1MiniMessage) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        output.lock()
        defer { output.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}
