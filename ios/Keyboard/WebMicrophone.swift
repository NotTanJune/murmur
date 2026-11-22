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
    /// Mono samples at the rate `onStarted` gave, and their RMS level.
    var onSamples: (([Float], Float) -> Void)?
    /// Capture stopped for a reason other than `stop()`, or never started.
    var onEnded: ((String) -> Void)?

    private(set) var isReady = false
    private(set) var isCapturing = false

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
        view.addSubview(webView)
        view.sendSubviewToBack(webView)
        webView.loadHTMLString(Self.page, baseURL: Self.baseURL)
    }

    /// Opens the microphone. Called on touch-down; if the page is still loading, capture
    /// starts as soon as it is ready.
    func start() {
        guard !isCapturing else { return }
        isCapturing = true
        startDeadline = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.end("no audio within 3 s (Full Access off, or permission missing?)") }
        }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.webView.evaluateJavaScript("murmurHeartbeat(); 0", completionHandler: nil) }
        }
        if isReady { begin() } else { startWhenReady = true }
    }

    /// Closes the microphone. No `onEnded` call: the caller asked for it.
    func stop() {
        guard isCapturing else { return }
        webView.evaluateJavaScript("murmurStop(); 0", completionHandler: nil)
        reset()
    }

    func tearDown() {
        stop()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mic")
        webView.removeFromSuperview()
    }

    private func begin() {
        startWhenReady = false
        webView.evaluateJavaScript("murmurStart(); 0") { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.end("start failed: \(error.localizedDescription)") }
        }
    }

    private func end(_ reason: String) {
        guard isCapturing else { return }
        Self.log.error("web microphone ended: \(reason, privacy: .public)")
        webView.evaluateJavaScript("murmurStop(); 0", completionHandler: nil)
        reset()
        onEnded?(reason)
    }

    private func reset() {
        isCapturing = false
        startWhenReady = false
        heartbeat?.invalidate()
        heartbeat = nil
        startDeadline?.invalidate()
        startDeadline = nil
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            if startWhenReady { begin() }
        case "started":
            // The deadline stays: a context that starts and then delivers nothing must still
            // fail with the microphone message. The first `audio` message cancels it.
            let rate = (message["rate"] as? NSNumber)?.doubleValue ?? 48_000
            Self.log.info("web microphone started at \(rate, format: .fixed(precision: 0)) Hz")
            onStarted?(rate)
        case "audio":
            guard isCapturing,
                  let text = message["data"] as? String,
                  let samples = PCMBridge.decodeFloat32(base64: text)
            else { return }
            startDeadline?.invalidate()
            startDeadline = nil
            onSamples?(samples, (message["rms"] as? NSNumber)?.floatValue ?? 0)
        case "ended":
            end(message["reason"] as? String ?? "unknown")
        default:
            break
        }
    }

    // The page sends samples at the context's own rate; Swift resamples (`PCMConverter`), so
    // the page never assumes a rate. The AudioContext is made only at start: creating one can
    // take audio focus or move a Bluetooth route while the keyboard is merely on screen.
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
    window.murmurStart = async () => {
      let done = false, stream, context, source, node, sink, watchdog;
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
        try { if (session) session.type = 'play-and-record'; } catch (_) {}
        stream = await navigator.mediaDevices.getUserMedia({
          audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true }
        });
        if (done) { stream.getTracks().forEach(t => t.stop()); return; }
        stream.getAudioTracks()[0].onended = () => fail('track ended');
        window.addEventListener('pagehide', onHide);
        context = new AudioContext({ latencyHint: 'interactive' });
        await context.resume();
        node = context.createScriptProcessor(2048, 1, 1);
        sink = context.createGain();
        sink.gain.value = 0;
        node.connect(sink);
        sink.connect(context.destination);
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
        post({ type: 'started', rate: context.sampleRate });
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
