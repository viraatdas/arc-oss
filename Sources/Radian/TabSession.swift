import AppKit
import Observation
import RadianCore
import WebKit

/// A loaded tab: one WKWebView plus the loading state the chrome draws from it.
@MainActor
@Observable
final class TabSession: NSObject {
    let id: UUID
    let webView: WKWebView

    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    @ObservationIgnored private weak var store: BrowserStore?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Set while the built-in error page is showing, so reload retries the page that failed.
    @ObservationIgnored private var failedURL: URL?
    @ObservationIgnored private var errorPageNavigation: WKNavigation?
    @ObservationIgnored private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    init(id: UUID, configuration: WKWebViewConfiguration, store: BrowserStore) {
        self.id = id
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.store = store
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        observeWebView()
    }

    private func observeWebView() {
        // WebKit delivers these on the main thread; the handlers are just not annotated as such.
        observations = [
            webView.observe(\.title) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publishPageState() }
            },
            webView.observe(\.url) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publishPageState() }
            },
            webView.observe(\.isLoading) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoading = self.webView.isLoading
                }
            },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.progress = self.webView.estimatedProgress
                }
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.canGoBack = self.webView.canGoBack
                }
            },
            webView.observe(\.canGoForward) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.canGoForward = self.webView.canGoForward
                }
            },
        ]
    }

    private func publishPageState() {
        // The error page has a title of its own; do not let it replace the real page's title.
        store?.sessionDidChange(id, title: failedURL == nil ? webView.title : nil, url: webView.url)
    }

    // MARK: - Navigation

    func load(_ url: URL) {
        failedURL = nil
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func reload() {
        if let failedURL {
            load(failedURL)
        } else {
            webView.reload()
        }
    }

    func stop() { webView.stopLoading() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func zoom(by step: Double) {
        webView.pageZoom = min(max(webView.pageZoom + step, 0.5), 3)
    }

    func resetZoom() {
        webView.pageZoom = 1
    }

    func find(_ text: String, backwards: Bool) async -> Bool {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        let result = try? await webView.find(text, configuration: configuration)
        return result?.matchFound ?? false
    }

    /// Releases the web view. Its content process exits once nothing else holds it.
    func teardown() {
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    // MARK: - Error page

    private func showErrorPage(for url: URL?, message: String) {
        failedURL = url
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Can’t open this page</title><style>
        :root { color-scheme: light dark; }
        body { font: 15px -apple-system, sans-serif; margin: 0; height: 100vh; display: grid; place-items: center;
               background: Canvas; color: CanvasText; }
        main { max-width: 440px; padding: 32px; text-align: center; }
        h1 { font-size: 22px; font-weight: 600; margin: 0 0 10px; }
        p { margin: 0 0 8px; opacity: .7; line-height: 1.45; }
        code { font: 12px ui-monospace, monospace; opacity: .55; word-break: break-all; }
        kbd { font: inherit; padding: 1px 6px; border: 1px solid color-mix(in srgb, CanvasText 25%, transparent); border-radius: 5px; }
        </style></head><body><main>
        <h1>Can’t open this page</h1>
        <p>\(escape(message))</p>
        <p>Press <kbd>⌘R</kbd> to try again.</p>
        <code>\(escape(url?.absoluteString ?? ""))</code>
        </main></body></html>
        """
        errorPageNavigation = webView.loadHTMLString(html, baseURL: url)
    }

    // MARK: - Dialogs

    private func makeAlert(message: String, detail: String = "") -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        return alert
    }

    private func pageName(_ frame: WKFrameInfo) -> String {
        let host = frame.securityOrigin.host
        return host.isEmpty ? "This page" : host
    }

    /// Dialogs attach to the window as sheets. A tab that is not on screen cannot show one, so it
    /// gets the answer a user would give by dismissing the dialog.
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse? {
        guard let window = webView.window, window.isVisible else { return nil }
        return await alert.beginSheetModal(for: window)
    }
}

// MARK: - WKNavigationDelegate

extension TabSession: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = navigationAction.request.url else { return (.allow, preferences) }
        if navigationAction.shouldPerformDownload { return (.download, preferences) }

        if !BrowserStore.isWebURL(url) {
            await offerToOpenExternally(url)
            return (.cancel, preferences)
        }
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command) {
            // ⌘-click opens in a background tab; ⇧⌘-click switches to it.
            store?.openTab(url: url, inBackground: !navigationAction.modifierFlags.contains(.shift))
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    /// Links such as mailto: or zoommtg: launch other apps, so a page never gets to do that silently.
    private func offerToOpenExternally(_ url: URL) async {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        let appName = FileManager.default.displayName(atPath: handler.path)
        let alert = makeAlert(
            message: "Open this link in \(appName)?",
            detail: "\(webView.url?.host ?? "This page") wants to open a link that \(appName) handles."
        )
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        if await present(alert) == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if navigation !== errorPageNavigation {
            failedURL = nil
            errorPageNavigation = nil
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard failedURL == nil, let url = webView.url else { return }
        store?.sessionDidFinish(id, title: webView.title ?? "", url: url)
        requestFavicon(for: url)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // A cancelled load, or one that turned into a download, is not a failure.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", [102, 204].contains(nsError.code) { return }
        let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url
        showErrorPage(for: url, message: nsError.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Reloading automatically could loop forever on a page that keeps crashing.
        showErrorPage(for: webView.url, message: "The page stopped unexpectedly.")
    }

    /// Asks the page which icon it declares, preferring one large enough to look sharp.
    private func requestFavicon(for pageURL: URL) {
        let script = """
        (() => {
          const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]')];
          const size = l => {
            const m = /(\\d+)x\\d+/.exec(l.getAttribute('sizes') || '');
            return m ? +m[1] : (l.rel.includes('apple') ? 180 : 16);
          };
          links.sort((a, b) => size(b) - size(a));
          const best = links.find(l => size(l) <= 256) || links[0];
          return best ? best.href : null;
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let href = result as? String, let iconURL = URL(string: href) else { return }
                self.store?.favicons.setIcon(iconURL, forPage: pageURL)
            }
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
}

// MARK: - WKUIDelegate

extension TabSession: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        store?.openPopupTab(configuration: configuration, url: navigationAction.request.url).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        store?.closeTab(id)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        _ = await present(makeAlert(message: "\(pageName(frame)) says", detail: message))
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        let alert = makeAlert(message: "\(pageName(frame)) asks", detail: message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let alert = makeAlert(message: "\(pageName(frame)) asks", detail: prompt)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        guard let window = webView.window, window.isVisible else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        // Let WebKit ask the user, and remember the answer per site.
        .prompt
    }
}

// MARK: - WKDownloadDelegate

extension TabSession: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destination = TabSession.uniqueDestination(in: directory, filename: suggestedFilename)
        downloadDestinations[ObjectIdentifier(download)] = destination
        store?.showToast("Downloading \(destination.lastPathComponent)", symbol: "arrow.down.circle.fill")
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        store?.showToast("Downloaded \(destination.lastPathComponent)", symbol: "arrow.down.circle.fill")
        // Makes the Downloads stack in the Dock bounce, as it does for other browsers.
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.DownloadFileFinished"),
            object: destination.path
        )
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        store?.showToast("Download failed", symbol: "exclamationmark.triangle.fill")
    }

    /// Never overwrites: "report.pdf" becomes "report 2.pdf" if the name is taken.
    static func uniqueDestination(in directory: URL, filename: String) -> URL {
        let safeName = (filename as NSString).lastPathComponent
        let name = safeName.isEmpty || safeName == "." || safeName == ".." ? "download" : safeName
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = pathExtension.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(pathExtension)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }
}
