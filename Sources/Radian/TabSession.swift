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

    /// The sheet currently showing a dialog for this page, if any.
    @ObservationIgnored private(set) var dialogWindow: NSWindow?

    @ObservationIgnored private weak var store: BrowserStore?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Set while the built-in error page is showing, so reload retries the page that failed.
    @ObservationIgnored private var failedURL: URL?
    @ObservationIgnored private var errorPageNavigation: WKNavigation?
    /// False until a page actually appears. A tab whose first load turns into a download never
    /// gets one and is removed.
    @ObservationIgnored private var hasCommittedNavigation = false

    // Limits on what a page can do to the user. Each resets when a new page loads.
    @ObservationIgnored private var dialogsShown = 0
    @ObservationIgnored private var dialogsSuppressed = false
    @ObservationIgnored private var declinedSchemes: Set<String> = []
    @ObservationIgnored private var isAskingAboutDownloads = false

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

    func printPage() {
        guard let window = webView.window else { return }
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        let operation = webView.printOperation(with: info)
        // Without a frame WebKit prints blank pages.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Releases the web view. Its content process exits once nothing else holds it.
    func teardown() {
        dismissDialog()
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    /// Closes any dialog this page has open, answering it as Cancel would.
    func dismissDialog() {
        guard let sheet = dialogWindow, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet, returnCode: .abort)
    }

    /// A new page is showing, so the limits placed on the previous one no longer apply.
    private func pageDidChange() {
        dialogsShown = 0
        dialogsSuppressed = false
        declinedSchemes = []
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

    /// Shows a sheet on the window. A tab the user cannot see cannot ask anything, so it gets the
    /// answer a user would give by dismissing the dialog.
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse? {
        guard let window = webView.window, window.isVisible, dialogWindow == nil else { return nil }
        dialogWindow = alert.window
        defer { dialogWindow = nil }
        return await alert.beginSheetModal(for: window)
    }

    /// Shows a dialog the page asked for with alert(), confirm() or prompt(). From the second
    /// dialog on, the user can stop the page showing more, which ends a page that loops them.
    private func presentPageDialog(_ alert: NSAlert) async -> NSApplication.ModalResponse? {
        guard !dialogsSuppressed else { return nil }
        dialogsShown += 1
        if dialogsShown > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don’t let this page show more dialogs"
        }
        let response = await present(alert)
        if alert.suppressionButton?.state == .on {
            dialogsSuppressed = true
        }
        return response
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
        if navigationAction.shouldPerformDownload {
            return (await mayDownload(url) ? .download : .cancel, preferences)
        }
        if !BrowserStore.isWebURL(url) {
            await offerToOpenExternally(url, from: navigationAction)
            return (.cancel, preferences)
        }
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command) {
            // ⌘-click opens in a background tab; ⇧⌘-click switches to it.
            store?.openTab(url: url, inBackground: !navigationAction.modifierFlags.contains(.shift))
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    /// Links such as mailto: or zoommtg: launch other apps, so a page never gets to do that
    /// silently. Frames inside the page, which are often ads, may not ask at all, and a page
    /// that was told no once is not allowed to ask again.
    private func offerToOpenExternally(_ url: URL, from action: WKNavigationAction) async {
        guard action.sourceFrame.isMainFrame, let scheme = url.scheme?.lowercased(),
              !declinedSchemes.contains(scheme),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url)
        else { return }
        let appName = FileManager.default.displayName(atPath: handler.path)
        let alert = makeAlert(
            message: "Open this link in \(appName)?",
            detail: "\(pageName(action.sourceFrame)) wants to open a link that \(appName) handles."
        )
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        if await present(alert) == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        } else {
            declinedSchemes.insert(scheme)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        var isAttachment = false
        if let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition") {
            isAttachment = disposition.lowercased().hasPrefix("attachment")
        }
        guard isAttachment || !navigationResponse.canShowMIMEType else { return .allow }
        // A frame inside the page cannot start a download by itself.
        guard navigationResponse.isForMainFrame else { return .cancel }
        return await mayDownload(navigationResponse.response.url) ? .download : .cancel
    }

    /// Downloads need the user's go-ahead once per site, and only from a tab they are looking at,
    /// so a background tab or a looping script cannot fill the Downloads folder.
    private func mayDownload(_ url: URL?) async -> Bool {
        guard let store, store.isShowing(id) else { return false }
        let host = (webView.url ?? url)?.host?.lowercased() ?? ""
        if store.downloadHosts.contains(host) { return true }
        guard !isAskingAboutDownloads else { return false }
        isAskingAboutDownloads = true
        defer { isAskingAboutDownloads = false }

        let file = url?.lastPathComponent ?? ""
        let alert = makeAlert(
            message: "Allow downloads from \(host.isEmpty ? "this page" : host)?",
            detail: file.isEmpty || file == "/"
                ? "The page wants to save a file to your Downloads folder."
                : "The page wants to save “\(file)” to your Downloads folder."
        )
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        guard await present(alert) == .alertFirstButtonReturn else { return false }
        store.downloadHosts.insert(host)
        return true
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasCommittedNavigation = true
        if navigation !== errorPageNavigation {
            failedURL = nil
            errorPageNavigation = nil
            pageDidChange()
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
        guard let store, store.isShowing(id) else {
            // Most likely macOS reclaimed the memory of a tab nobody was looking at. Let it
            // sleep and load afresh when it is next shown, rather than greet the user with an error.
            store?.sessionDidCrashOffScreen(id)
            return
        }
        // Reloading automatically could loop forever on a page that keeps crashing.
        showErrorPage(for: webView.url, message: "The page stopped unexpectedly.")
    }

    func webView(
        _ webView: WKWebView,
        respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let methods = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM]
        // Certificates and everything else get WebKit's standard handling.
        guard methods.contains(space.authenticationMethod) else { return (.performDefaultHandling, nil) }
        guard challenge.previousFailureCount < 3, store?.isShowing(id) == true,
              let credential = await askForCredential(for: space, afterFailure: challenge.previousFailureCount > 0)
        else {
            // Carry on without logging in, which shows the site's own "unauthorized" page.
            return (.rejectProtectionSpace, nil)
        }
        return (.useCredential, credential)
    }

    private func askForCredential(for space: URLProtectionSpace, afterFailure: Bool) async -> URLCredential? {
        var lines: [String] = []
        if afterFailure { lines.append("That name and password were not accepted.") }
        if let realm = space.realm, !realm.isEmpty { lines.append("The site says: “\(realm)”") }
        if !space.receivesCredentialSecurely { lines.append("Your password will be sent unencrypted.") }
        let alert = makeAlert(message: "Log in to \(space.host)", detail: lines.joined(separator: "\n"))

        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = "Name"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = "Password"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        fields.addSubview(user)
        fields.addSubview(password)
        user.nextKeyView = password
        alert.accessoryView = fields
        alert.window.initialFirstResponder = user
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")

        guard await present(alert) == .alertFirstButtonReturn else { return nil }
        return URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession)
    }

    /// Asks the page which icon it declares, preferring one large enough to look sharp. Vector
    /// icons are skipped: they would have to be rendered outside WebKit's sandbox.
    private func requestFavicon(for pageURL: URL) {
        let script = """
        (() => {
          const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]')]
            .filter(l => l.type !== 'image/svg+xml' && !/\\.svg(\\?|#|$)/i.test(l.href));
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
        adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        adopt(download)
    }

    private func adopt(_ download: WKDownload) {
        download.delegate = store?.downloads
        if !hasCommittedNavigation {
            // The tab was opened only to fetch this file and would otherwise sit there blank,
            // downloading it again every time it was reopened.
            store?.discardDownloadTab(id)
        }
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
        store?.openPopupTab(configuration: configuration, url: navigationAction.request.url, openedBy: id)?.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        store?.closeTab(id)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        _ = await presentPageDialog(makeAlert(message: "\(pageName(frame)) says", detail: message))
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        let alert = makeAlert(message: "\(pageName(frame)) asks", detail: message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await presentPageDialog(alert) == .alertFirstButtonReturn
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
        return await presentPageDialog(alert) == .alertFirstButtonReturn ? field.stringValue : nil
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
