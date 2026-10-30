import Darwin

// The S1-mini helper is this same executable with `--s1-server`. It has to branch off
// before SwiftUI starts the app: no Dock icon, no windows, no hotkey monitor.
if CommandLine.arguments.contains("--s1-server") {
    S1MiniServer.run()
}

// Writing to a helper that just exited must surface as an error, not kill the app.
signal(SIGPIPE, SIG_IGN)
MurmurApp.main()
