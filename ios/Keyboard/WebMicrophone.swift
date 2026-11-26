import MurmurKit
import OSLog
import UIKit
import WebKit

/// The microphone for a keyboard extension, borrowed from WebKit.
///
/// iOS does not let a keyboard extension record: it lacks the entitlement, so `AVAudioEngine`
/// and audio queues fail inside it. A `WKWebView` in the keyboard's own view hierarchy can
/// still call `getUserMedia`, because WebKit records in its own media process under the
/// containing app's microphone permission. The page sends the samples back over a script
/// message handler. Shown by Raycast in November 2026; reference implementations are
/// `stephancill/ios-keyboard-dictation` and Hex's keyboard (both MIT), read for the technique.
///
/// Apple may close this path at any time, so every failure is reported through `onEnded`
/// with a reason, never swallowed.
@MainActor
final class WebMicrophone: NSObject {
    /// Capture began; the argument is the page's sample rate (usually 48 kHz, but 16 kHz on a
    /// Bluetooth headset and 44.1 kHz on some routes).
    var onStarted: ((Double) -> Void)?
    /// Mono samples at the rate `onStarted` gave, and their RMS level. Delivered continuously
    /// from the first block until `close()`, whether or not a hold is listening: the caller
    /// decides what to do with audio that arrives between holds.
    var onSamples: (([Float], Float) -> Void)?
    /// Capture stopped for a reason other than `close()`, or never started.
    var onEnded: ((String) -> Void)?

    /// How the page captures. The microphone's orange indicator cannot be avoided, but a page
    /// whose audio graph feeds the context's output also makes WebKit report it as playing
    /// audio, and the Dynamic Island then shows a speaker beside the dot. `recordOnly` leaves
    /// the output unconnected; `playAndRecord` is the original setup that is known to deliver
    /// audio, kept as the fallback.
    enum CaptureMode: String {
        case recordOnly
        case playAndRecord

        var displayName: String {
            switch self {
            case .recordOnly: "record-only"
            case .playAndRecord: "play-and-record"
            }
        }
    }

    private(set) var isReady = false
    /// The microphone is open: opening, or delivering samples.
    private(set) var isCapturing = false
    /// The mode the next start (or the current one) uses.
    private(set) var mode = CaptureMode.recordOnly
    /// The mode that last delivered audio, in this process or an earlier one; nil before any.
    private(set) var confirmedMode: CaptureMode?

    /// Shared defaults key for `confirmedMode`, so the next process starts with what worked.
    private static let modeKey = "keyboardCaptureMode"
    /// How long a started page may stay silent in `recordOnly` before the fallback.
    private static let silentSeconds: TimeInterval = 1.5
    /// Read once, in `attach`: this object is created before `PhoneEnvironment.configure()` runs.
    private var modeLoaded = false
    /// This open already fell back; it falls back at most once.
    private var triedFallback = false
    /// This open has delivered its first audio.
    private var hasAudio = false
    /// Page runs are numbered so that messages from a run that was stopped (a fallback replaces
    /// a record-only run with a play-and-record one) are never taken for the new run's.
    private var run = 0
    private var silentDeadline: Timer?

    private let webView: WKWebView
    private var heartbeat: Timer?
    private var startDeadline: Timer?
    private var startWhenReady = false
    private static let log = Logger(subsystem: "ai.pivotstudio.murmur", category: "audio")
    private static let baseURL = URL(string: "https://murmur-keyboard.invalid/")!

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        super.init()
        configuration.userContentController.add(MessageRelay(self), name: "mic")
        webView.uiDelegate = self
        webView.navigationDelegate = self
        // Not hidden and not removed: WebKit throttles a web view that is outside a window.
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
    }

    /// Puts the web view into the keyboard's hierarchy and loads the page. The https base URL
    /// is never fetched; it gives the page the secure context `getUserMedia` requires.
    func attach(to view: UIView) {
        loadStoredMode()
        view.addSubview(webView)
        view.sendSubviewToBack(webView)
        webView.loadHTMLString(Self.page, baseURL: Self.baseURL)
    }

    private func loadStoredMode() {
        guard !modeLoaded else { return }
        modeLoaded = true
        guard let raw = MurmurEnvironment.defaults.string(forKey: Self.modeKey),
              let stored = CaptureMode(rawValue: raw) else { return }
        confirmedMode = stored
        // One silence must not pin play-and-record for good: each process tries record-only
        // once more and follows the result (a silent open falls back and stores the outcome).
        mode = .recordOnly
    }

    /// Opens the microphone and keeps it open until `close()`. The keyboard calls it when it
    /// appears (a warm microphone) or, with that setting off, at touch-down. If the page is
    /// still loading, capture starts as soon as it is ready. The heartbeat runs from here; the
    /// 3 s "no audio" deadline runs from the moment the page is asked to start (`begin()`), so
    /// page load and WebContent launch do not count against it, and a page that never loads
    /// has its own longer deadline. A keyboard that froze or has no permission therefore does
    /// not leave the microphone open or the key waiting. Opening twice is a no-op.
    func open() {
        guard !isCapturing else { return }
        loadStoredMode()
        isCapturing = true
        triedFallback = false
        hasAudio = false
        if !isReady {
            startDeadline = scheduled(after: Self.pageLoadSeconds, repeats: false) { [weak self] in
                self?.end("page did not load within \(Int(Self.pageLoadSeconds)) s")
            }
        }
        heartbeat = scheduled(after: 1, repeats: true) { [weak self] in
            self?.webView.evaluateJavaScript("murmurHeartbeat(); 0", completionHandler: nil)
        }
        if isReady { begin() } else { startWhenReady = true }
    }

    /// How long the page may take to load before capture is reported as failed.
    private static let pageLoadSeconds: TimeInterval = 10
    /// How long a started page may take to deliver its first audio.
    private static let firstAudioSeconds: TimeInterval = 3

    /// A timer on the main run loop in the common modes. `Timer.scheduledTimer` uses the
    /// default mode only, which stops while a `ScrollView` tracks a finger (the emoji and
    /// history panels), and about 3 s of that scrolling would starve the page's heartbeat
    /// watchdog and end capture.
    private func scheduled(
        after interval: TimeInterval, repeats: Bool, _ fire: @escaping @MainActor () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
            Task { @MainActor in fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Closes the microphone. No `onEnded` call: the caller asked for it.
    func close() {
        guard isCapturing else { return }
        webView.evaluateJavaScript("murmurStop(); 0", completionHandler: nil)
        reset()
    }

    func tearDown() {
        close()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mic")
        webView.removeFromSuperview()
    }

    private func begin() {
        startWhenReady = false
        silentDeadline?.invalidate()
        silentDeadline = nil
        run += 1
        Self.log.info("web microphone starting in \(self.mode.rawValue, privacy: .public) mode")
        startDeadline?.invalidate()
        startDeadline = scheduled(after: Self.firstAudioSeconds, repeats: false) { [weak self] in
            self?.noAudio("no audio within \(Int(Self.firstAudioSeconds)) s (Full Access off, or permission missing?)")
        }
        webView.evaluateJavaScript("murmurStart('\(mode.rawValue)', \(run)); 0") { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.end("start failed: \(error.localizedDescription)") }
        }
    }

    /// No audio arrived in time. In `recordOnly` that may only mean WebKit does not process a
    /// graph whose output is unconnected, so the page is restarted once in `playAndRecord`
    /// instead of reporting the permissions failure; every other case, and a second silence,
    /// fails as before. The fallback is allowed once per open, even if record-only worked on an
    /// earlier open: the remembered mode changes only when an open delivers audio.
    private func noAudio(_ reason: String) {
        guard isCapturing else { return }
        guard mode == .recordOnly, !triedFallback else {
            end(reason)
            return
        }
        triedFallback = true
        Self.log.error("record-only capture delivered no audio (\(reason, privacy: .public)); falling back to play-and-record")
        webView.evaluateJavaScript("murmurStop(); 0", completionHandler: nil)
        mode = .playAndRecord
        begin()
    }

    private func end(_ reason: String) {
        guard isCapturing else { return }
        Self.log.error("web microphone ended: \(reason, privacy: .public)")
        webView.evaluateJavaScript("murmurStop(); 0", completionHandler: nil)
        // A fallback that did not help (permission missing, say) must not leave the next open
        // in play-and-record for good: only a mode that delivered audio is kept.
        if !hasAudio, triedFallback { mode = confirmedMode ?? .recordOnly }
        reset()
        onEnded?(reason)
    }

    private func reset() {
        isCapturing = false
        run += 1
        startWhenReady = false
        heartbeat?.invalidate()
        heartbeat = nil
        startDeadline?.invalidate()
        startDeadline = nil
        silentDeadline?.invalidate()
        silentDeadline = nil
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        if type == "ready" {
            isReady = true
            if startWhenReady { begin() }
            return
        }
        // Everything else belongs to a numbered run; a stopped run's late messages are dropped.
        guard (message["run"] as? NSNumber)?.intValue == run else { return }
        switch type {
        case "started":
            // The deadline stays: a context that starts and then delivers nothing must still
            // fail with the microphone message. The first `audio` message cancels it.
            let rate = (message["rate"] as? NSNumber)?.doubleValue ?? 48_000
            let session = message["session"] as? String ?? "unsupported"
            Self.log.info("web microphone started at \(rate, format: .fixed(precision: 0)) Hz, \(self.mode.rawValue, privacy: .public), audio session \(session, privacy: .public)")
            // Record-only has its own, shorter silence limit, counted from a running context
            // so a slow permission prompt or route change does not count against it.
            if mode == .recordOnly, !triedFallback, !hasAudio {
                silentDeadline?.invalidate()
                silentDeadline = scheduled(after: Self.silentSeconds, repeats: false) { [weak self] in
                    self?.noAudio("no audio \(Self.silentSeconds) s after the page started")
                }
            }
            onStarted?(rate)
        case "audio":
            guard isCapturing,
                  let text = message["data"] as? String,
                  let samples = PCMBridge.decodeFloat32(base64: text)
            else { return }
            startDeadline?.invalidate()
            startDeadline = nil
            silentDeadline?.invalidate()
            silentDeadline = nil
            if !hasAudio { confirm() }
            onSamples?(samples, (message["rms"] as? NSNumber)?.floatValue ?? 0)
        case "ended":
            end(message["reason"] as? String ?? "unknown")
        default:
            break
        }
    }

    /// The first audio of this open arrived in `mode`: remember it, here and for the next
    /// process.
    private func confirm() {
        hasAudio = true
        Self.log.info("capture mode \(self.mode.rawValue, privacy: .public) delivered audio")
        guard confirmedMode != mode else { return }
        confirmedMode = mode
        MurmurEnvironment.defaults.set(mode.rawValue, forKey: Self.modeKey)
    }

    // The page sends samples at the context's own rate; Swift resamples (`PCMConverter`), so
    // the page never assumes a rate. The AudioContext is made only when the microphone opens:
    // creating one can take audio focus or move a Bluetooth route while the keyboard is merely on screen.
    private static let page = """
    <!doctype html><html><body><script>
    const post = m => window.webkit.messageHandlers.mic.postMessage(m);
    const toBase64 = floats => {
      const bytes = new Uint8Array(floats.buffer, floats.byteOffset, floats.byteLength);
      let text = '';
      for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
      return btoa(text);
    };
    let lastBeat = performance.now();
    let stop = () => {};
    window.murmurHeartbeat = () => { lastBeat = performance.now(); };
    window.murmurStop = () => stop();
    window.murmurStart = async (mode, run) => {
      let done = false, stream, context, source, node, sink, watchdog;
      const post = m => window.webkit.messageHandlers.mic.postMessage(Object.assign({ run }, m));
      const recordOnly = mode === 'recordOnly';
      const session = navigator.audioSession;
      const previous = session ? session.type : 'auto';
      const close = () => {
        if (done) return;
        done = true;
        clearInterval(watchdog);
        if (node) { node.onaudioprocess = null; node.disconnect(); }
        if (source) source.disconnect();
        if (sink) sink.disconnect();
        if (stream) stream.getTracks().forEach(t => t.stop());
        if (context) context.close().catch(() => {});
        try { if (session) session.type = previous; } catch (_) {}
        window.removeEventListener('pagehide', onHide);
      };
      const fail = reason => { if (!done) { close(); post({ type: 'ended', reason }); } };
      const onHide = () => fail('page hidden');
      stop = close;
      try {
        // The spec's session types have no record-only value; 'record' is tried in case this
        // WebKit accepts it, and read back. Anything else keeps the setup that is known to work.
        try {
          if (session) {
            session.type = recordOnly ? 'record' : 'play-and-record';
            if (recordOnly && session.type !== 'record') session.type = 'play-and-record';
          }
        } catch (_) {}
        stream = await navigator.mediaDevices.getUserMedia({
          audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true }
        });
        if (done) { stream.getTracks().forEach(t => t.stop()); return; }
        stream.getAudioTracks()[0].onended = () => fail('track ended');
        window.addEventListener('pagehide', onHide);
        context = new AudioContext({ latencyHint: 'interactive' });
        await context.resume();
        if (done) return;
        node = context.createScriptProcessor(2048, 1, 1);
        if (recordOnly) {
          // Nothing reaches context.destination. An AnalyserNode with no output is pulled by
          // the context on its own, which keeps the processor running without an output path;
          // if this WebKit does not, Swift falls back to the mode below.
          sink = context.createAnalyser();
          node.connect(sink);
        } else {
          sink = context.createGain();
          sink.gain.value = 0;
          node.connect(sink);
          sink.connect(context.destination);
        }
        source = context.createMediaStreamSource(stream);
        source.connect(node);
        context.onstatechange = () => { if (context.state !== 'running') fail('audio context ' + context.state); };
        if (session) session.onstatechange = () => { if (session.state === 'interrupted') fail('audio session interrupted'); };
        lastBeat = performance.now();
        watchdog = setInterval(() => { if (performance.now() - lastBeat > 3000) fail('no heartbeat from the keyboard for 3 s'); }, 500);
        node.onaudioprocess = event => {
          const samples = new Float32Array(event.inputBuffer.getChannelData(0));
          let energy = 0;
          for (let i = 0; i < samples.length; i++) energy += samples[i] * samples[i];
          post({ type: 'audio', data: toBase64(samples), rms: Math.sqrt(energy / samples.length) });
        };
        post({ type: 'started', rate: context.sampleRate, session: session ? session.type : 'unsupported' });
      } catch (error) {
        fail(error.name + ': ' + error.message);
      }
    };
    post({ type: 'ready' });
    </script></body></html>
    """
}

extension WebMicrophone: WKUIDelegate, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        end("WebKit's content process ended")
        webView.loadHTMLString(Self.page, baseURL: Self.baseURL)
    }
}

/// Holds the microphone weakly: `WKUserContentController` retains its handlers, which would
/// otherwise keep the keyboard's controller alive after the keyboard goes away.
@MainActor
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    weak var target: WebMicrophone?
    init(_ target: WebMicrophone) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message.body)
    }
}
