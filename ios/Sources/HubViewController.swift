import AVFoundation
import MediaPlayer
import UIKit
import WebKit

/// Shows the bundled web app (index.html, app.js, ...) and gives it a native
/// bridge, `window.IRNative`, for blasting through audio, clipboard and sharing.
final class HubViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    private var webView: WKWebView!
    private let blaster = AudioBlaster()
    private let volumeView = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 100, height: 40))
    private var volumeObservation: NSKeyValueObservation?

    private static let bridgeScript = """
    window.IRNative = (() => {
      const call = (action, data = {}) => window.webkit.messageHandlers.irblaster.postMessage({ action, ...data });
      return {
        platform: 'ios',
        blast: (sig, opts) => call('blast', { freq: sig.freq, timings: sig.timings, mode: opts.mode, repeats: opts.repeats, invert: !!opts.invert }),
        status: () => call('status'),
        maxVolume: () => call('maxVolume'),
        copy: (text) => call('copy', { text }),
        share: (filename, text) => call('share', { filename, text }),
      };
    })();
    """

    override func loadView() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addScriptMessageHandler(self, contentWorld: .page, name: "irblaster")
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0x0f / 255, green: 0x12 / 255, blue: 0x16 / 255, alpha: 1)
            : UIColor(red: 0xf5 / 255, green: 0xf6 / 255, blue: 0xf8 / 255, alpha: 1) }
        view = webView

        // A hidden system volume slider: the only way an app can turn the volume up.
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        view.addSubview(volumeView)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        blaster.activateSession()

        NotificationCenter.default.addObserver(self, selector: #selector(pushStatus),
                                               name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pushStatus),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] _, _ in
            DispatchQueue.main.async { self?.pushStatus() }
        }

        guard let web = Bundle.main.url(forResource: "Web", withExtension: nil) else { return }
        webView.loadFileURL(web.appendingPathComponent("index.html"), allowingReadAccessTo: web)
    }

    /// Tells the page where audio is going (blaster plugged in, volume, ...).
    @objc private func pushStatus() {
        DispatchQueue.main.async { [self] in
            guard let data = try? JSONSerialization.data(withJSONObject: blaster.status()),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('irnative-status', { detail: \(json) }))")
        }
    }

    // MARK: - Bridge

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else {
            return replyHandler(nil, "Bad message")
        }
        switch action {
        case "blast":
            let freq = (body["freq"] as? NSNumber)?.doubleValue ?? 0
            let timings = (body["timings"] as? [NSNumber])?.map(\.doubleValue) ?? []
            let repeats = (body["repeats"] as? NSNumber)?.intValue ?? 1
            let invert = (body["invert"] as? Bool) ?? false
            let full = (body["mode"] as? String) == "full"
            do {
                let result = try blaster.blast(freq: freq, timings: timings, fullCarrier: full, repeats: repeats, invert: invert)
                var reply = blaster.status()
                reply["toneHz"] = result.toneHz
                reply["sampleRate"] = result.sampleRate
                replyHandler(reply, nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        case "status":
            replyHandler(blaster.status(), nil)
        case "maxVolume":
            let slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
            slider?.setValue(1, animated: false)
            slider?.sendActions(for: .valueChanged)
            replyHandler(slider != nil, nil)
        case "copy":
            UIPasteboard.general.string = body["text"] as? String ?? ""
            replyHandler(true, nil)
        case "share":
            let name = (body["filename"] as? String ?? "codes.txt").replacingOccurrences(of: "/", with: "_")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            do {
                try (body["text"] as? String ?? "").write(to: url, atomically: true, encoding: .utf8)
                let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = view
                sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                present(sheet, animated: true)
                replyHandler(true, nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        default:
            replyHandler(nil, "Unknown action \(action)")
        }
    }

    // MARK: - Links

    /// Web links (IRDB, source CSVs) open in Safari; the app itself stays on the bundled page.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https",
           navigationAction.targetFrame?.isMainFrame ?? true {
            UIApplication.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { UIApplication.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushStatus()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}
