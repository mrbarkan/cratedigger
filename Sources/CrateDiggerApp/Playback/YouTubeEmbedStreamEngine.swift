import AppKit
import CrateDiggerCore
import Foundation
import WebKit

/// WebView playback engine: hosts a hidden `WKWebView`, loads the stream's
/// YouTube page, and drives the page's `<video>` element via injected JS.
/// Zero-config (no binary), ToS-compliant. It's the "lite" engine — output-device
/// routing and real codec/buffer readouts aren't available here.
@MainActor
final class YouTubeEmbedStreamEngine: NSObject, RadioPlaybackEngine {

    var onStateChange: ((RadioEngineState) -> Void)?
    var onTimeChange: ((Double, Double) -> Void)?

    private var webView: WKWebView?
    private var volume: Double = 0.8
    private let handler = ScriptMessageHandler()

    // Injected at document end: find the <video>, autoplay it, and report state.
    private static let controlScript = """
    (function(){
      function send(m){ try{ window.webkit.messageHandlers.cd.postMessage(m); }catch(e){} }
      var v=null;
      function bind(el){
        el.addEventListener('playing', function(){ send('state:playing'); });
        el.addEventListener('play',    function(){ send('state:playing'); });
        el.addEventListener('pause',   function(){ send('state:paused'); });
        el.addEventListener('waiting', function(){ send('state:loading'); });
        el.addEventListener('error',   function(){ send('error:media'); });
        el.addEventListener('timeupdate', function(){
          send('time:' + el.currentTime + ':' + (isFinite(el.duration) ? el.duration : 0));
        });
        try { el.muted=false; el.play(); } catch(e){}
      }
      function tick(){
        var el = document.querySelector('video');
        if (el && el !== v) { v = el; bind(el); }
        if (v && !v.paused) { send('state:playing'); }
      }
      setInterval(tick, 1000);
      tick();
    })();
    """

    func play(_ stream: StreamSource) {
        onStateChange?(.loading)
        let web = ensureWebView()
        web.configuration.userContentController.removeAllUserScripts()
        let script = WKUserScript(source: Self.controlScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        web.configuration.userContentController.addUserScript(script)

        guard let url = normalizedURL(stream.url) else {
            onStateChange?(.failed("Could not load that link."))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        web.load(request)
    }

    func pause() {
        evaluate("var v=document.querySelector('video'); if(v) v.pause();")
        onStateChange?(.paused)
    }

    func resume() {
        evaluate("var v=document.querySelector('video'); if(v){ v.muted=false; v.play(); }")
    }

    func stop() {
        webView?.stopLoading()
        webView?.loadHTMLString("<html><body style='background:#000'></body></html>", baseURL: nil)
        onStateChange?(.idle)
    }

    func setVolume(_ volume: Double) {
        self.volume = max(0, min(volume, 1))
        evaluate("var v=document.querySelector('video'); if(v){ v.volume=\(self.volume); v.muted=false; }")
    }

    func seek(toSeconds seconds: Double) {
        evaluate("var v=document.querySelector('video'); if(v && isFinite(v.duration)) v.currentTime=\(max(0, seconds));")
    }

    // MARK: - Internals

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        let ucc = WKUserContentController()
        handler.onMessage = { [weak self] msg in self?.handle(message: msg) }
        ucc.add(handler, name: "cd")
        config.userContentController = ucc

        // Tiny, effectively-invisible webview parented to the app window so media
        // is allowed to play (offscreen/detached webviews get throttled).
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        web.navigationDelegate = self
        web.alphaValue = 0.0
        if let host = NSApp.mainWindow?.contentView ?? NSApp.windows.first?.contentView {
            web.translatesAutoresizingMaskIntoConstraints = true
            web.frame = NSRect(x: 0, y: 0, width: 2, height: 2)
            host.addSubview(web)
        }
        webView = web
        return web
    }

    private func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil {
            return URL(string: trimmed)
        }
        return URL(string: "https://" + trimmed)
    }

    private func evaluate(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func handle(message: String) {
        if message.hasPrefix("state:") {
            switch String(message.dropFirst("state:".count)) {
            case "playing": onStateChange?(.playing)
            case "paused":  onStateChange?(.paused)
            case "loading": onStateChange?(.loading)
            default: break
            }
        } else if message.hasPrefix("time:") {
            let parts = message.dropFirst("time:".count).split(separator: ":")
            if parts.count == 2, let cur = Double(parts[0]), let dur = Double(parts[1]) {
                onTimeChange?(cur, dur)
            }
        } else if message.hasPrefix("error:") {
            onStateChange?(.failed("YouTube playback error."))
        }
    }
}

extension YouTubeEmbedStreamEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Re-apply volume once the page is up.
        evaluate("var v=document.querySelector('video'); if(v){ v.volume=\(volume); v.muted=false; }")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onStateChange?(.failed(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onStateChange?(.failed(error.localizedDescription))
    }
}

/// Bridges `WKScriptMessageHandler` (delivered on the main thread) to a closure
/// on the main actor. Kept separate so the engine doesn't expose the protocol method.
private final class ScriptMessageHandler: NSObject, WKScriptMessageHandler {
    var onMessage: ((String) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        MainActor.assumeIsolated { onMessage?(body) }
    }
}
