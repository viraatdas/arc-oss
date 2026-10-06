import AppKit
import RadianCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let store = BrowserStore()
    private var windowController: BrowserWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(target: self)
        let controller = BrowserWindowController(store: store)
        windowController = controller
        controller.showWindow(nil)
        store.start()
        NSApp.activate(ignoringOtherApps: true)

        if let notice = store.stateNotice {
            explain(notice)
        } else if store.isFirstLaunch {
            offerArcImport()
        }
    }

    /// Links clicked in other apps arrive here when Radian is the default browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        showWindow()
        for url in urls {
            store.open(url, mode: .newTab)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            showWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - File

    @objc func newTab(_ sender: Any?) {
        showWindow()
        store.presentCommandBar(.newTab)
    }

    @objc func openLocation(_ sender: Any?) {
        showWindow()
        store.presentCommandBar(.currentTab)
    }

    @objc func closeTab(_ sender: Any?) {
        // ⌘W closes whatever is frontmost: a sheet or panel first, then the tab.
        if let keyWindow = NSApp.keyWindow, keyWindow !== windowController?.window {
            if let session = store.session(presentingDialogIn: keyWindow) {
                // A page's own dialog cannot be closed, only answered. Closing the tab behind it
                // is the way out of a page that keeps showing them.
                session.dismissDialog()
                store.closeTab(session.id)
            } else {
                keyWindow.performClose(sender)
            }
        } else if store.commandBar != nil {
            store.dismissCommandBar()
        } else {
            store.closeFocusedTab()
        }
    }

    @objc func printPage(_ sender: Any?) { store.focusedSession?.printPage() }

    @objc func reopenClosedTab(_ sender: Any?) { store.reopenClosedTab() }
    @objc func newFolder(_ sender: Any?) { store.newFolder() }

    // MARK: - Edit

    @objc func findInPage(_ sender: Any?) { store.requestFindBar() }

    @objc func copyLink(_ sender: Any?) {
        if let id = store.focusedTabID { store.copyLink(of: id) }
    }

    // MARK: - View

    @objc func toggleSidebar(_ sender: Any?) { store.toggleSidebar() }
    // Page commands act on whichever split pane has keyboard focus.
    @objc func reloadPage(_ sender: Any?) { store.focusedSession?.reload() }
    @objc func stopLoading(_ sender: Any?) { store.focusedSession?.stop() }
    @objc func zoomIn(_ sender: Any?) { store.focusedSession?.zoom(by: 0.1) }
    @objc func zoomOut(_ sender: Any?) { store.focusedSession?.zoom(by: -0.1) }
    @objc func actualSize(_ sender: Any?) { store.focusedSession?.resetZoom() }
    @objc func toggleSplit(_ sender: Any?) { store.toggleSplit() }

    // MARK: - Tabs

    @objc func goBack(_ sender: Any?) { store.focusedSession?.goBack() }
    @objc func goForward(_ sender: Any?) { store.focusedSession?.goForward() }
    @objc func nextTab(_ sender: Any?) { store.selectAdjacentTab(offset: 1) }
    @objc func previousTab(_ sender: Any?) { store.selectAdjacentTab(offset: -1) }

    @objc func togglePin(_ sender: Any?) {
        if let id = store.focusedTabID { store.togglePin(id) }
    }

    @objc func addToFavorites(_ sender: Any?) {
        if let id = store.focusedTabID { store.addToFavorites(id) }
    }

    /// The menu item's tag is the zero-based position of the tab.
    @objc func selectTabByPosition(_ sender: NSMenuItem) {
        store.selectTab(atPosition: sender.tag)
    }

    @objc func showArchive(_ sender: Any?) { store.isArchivePresented = true }

    // MARK: - Spaces

    @objc func newSpace(_ sender: Any?) { store.newSpace() }
    @objc func editSpace(_ sender: Any?) { store.editingSpaceID = store.state.currentSpaceID }
    @objc func nextSpace(_ sender: Any?) { store.cycleSpace(by: 1) }
    @objc func previousSpace(_ sender: Any?) { store.cycleSpace(by: -1) }

    @objc func selectSpaceByPosition(_ sender: NSMenuItem) {
        store.selectSpace(atPosition: sender.tag)
    }

    // MARK: - App

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "An open-source browser with spaces, pinned tabs and a command bar.\n"
                + "Built on WebKit. Independent, and not affiliated with The Browser Company.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func importFromArc(_ sender: Any?) {
        var url = ArcImporter.defaultSidebarURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let panel = NSOpenPanel()
            panel.message = "Arc was not found in its usual place. Choose its StorableSidebar.json file."
            panel.allowedContentTypes = [.json]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }

        let alert = NSAlert()
        do {
            let (stats, summary) = try store.importFromArc(at: url)
            if summary.addedSpaceIDs.isEmpty, summary.addedFavorites == 0 {
                alert.messageText = "Nothing new to import"
                alert.informativeText = "Every space in Arc has already been imported. "
                    + "To import one again, delete it here first."
            } else {
                alert.messageText = "Imported from Arc"
                alert.informativeText = AppDelegate.describe(stats, summary)
            }
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Could not import from Arc"
            alert.informativeText = error.localizedDescription
        }
        present(alert)
    }

    private static func describe(_ stats: ArcImportResult.Stats, _ summary: ArcMergeSummary) -> String {
        func count(_ value: Int, _ singular: String) -> String {
            "\(value) \(singular)\(value == 1 ? "" : "s")"
        }
        var lines = [
            count(summary.addedSpaceIDs.count, "space"),
            count(stats.pinnedTabs, "pinned tab") + (stats.folders > 0 ? " in \(count(stats.folders, "folder"))" : ""),
            count(stats.unpinnedTabs, "open tab"),
        ]
        if summary.addedFavorites > 0 { lines.append(count(summary.addedFavorites, "favorite")) }
        var text = lines.joined(separator: "\n")
        if summary.skippedSpaces > 0 {
            text += "\n\n\(count(summary.skippedSpaces, "space")) had been imported before and were left as they are."
        }
        text += "\n\nArc itself was not changed. Sign in to sites again here: logins do not carry over."
        return text
    }

    private func offerArcImport() {
        guard FileManager.default.fileExists(atPath: ArcImporter.defaultSidebarURL.path),
              let window = windowController?.window
        else { return }
        let alert = NSAlert()
        alert.messageText = "Bring your spaces over from Arc?"
        alert.informativeText = "Radian found Arc on this Mac. It can copy your spaces, pinned tabs, folders "
            + "and favorites. Arc itself is not changed, and you can do this later from the Radian menu."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.importFromArc(nil) }
        }
    }

    private func present(_ alert: NSAlert, then handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let window = windowController?.window, window.isVisible {
            alert.beginSheetModal(for: window) { response in handler?(response) }
        } else {
            handler?(alert.runModal())
        }
    }

    private func showWindow() {
        windowController?.showWindow(nil)
        store.windowDidShow()
    }

    /// Tells the user what happened to saved state that could not be used as it was.
    private func explain(_ notice: StateNotice) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch notice {
        case .unreadable(let location):
            alert.messageText = "Radian couldn’t read its saved spaces"
            alert.informativeText = "It has started with a fresh window. Nothing was deleted: the saved file was kept "
                + "as “\(location.lastPathComponent)” so it can be recovered."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show in Finder")
            present(alert) { response in
                if response == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([location])
                }
            }
        case .newerVersion(let backup):
            alert.messageText = "These spaces were saved by a newer version of Radian"
            alert.informativeText = "Anything this version does not understand may be lost when it saves. "
                + (backup.map { "A copy of the original was kept as “\($0.lastPathComponent)”." } ?? "")
            present(alert)
        }
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let windowIsOpen = windowController?.window?.isVisible == true
        switch menuItem.action {
        case #selector(reloadPage(_:)), #selector(stopLoading(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
             #selector(actualSize(_:)), #selector(printPage(_:)), #selector(findInPage(_:)):
            return windowIsOpen && store.focusedSession != nil
        case #selector(goBack(_:)):
            return windowIsOpen && store.focusedSession?.canGoBack == true
        case #selector(goForward(_:)):
            return windowIsOpen && store.focusedSession?.canGoForward == true
        case #selector(closeTab(_:)):
            return NSApp.keyWindow != nil || windowIsOpen
        case #selector(copyLink(_:)), #selector(togglePin(_:)), #selector(addToFavorites(_:)),
             #selector(toggleSplit(_:)):
            return windowIsOpen && store.focusedTabID != nil
        case #selector(nextTab(_:)), #selector(previousTab(_:)), #selector(selectTabByPosition(_:)),
             #selector(nextSpace(_:)), #selector(previousSpace(_:)), #selector(selectSpaceByPosition(_:)),
             #selector(toggleSidebar(_:)), #selector(newFolder(_:)), #selector(editSpace(_:)), #selector(showArchive(_:)):
            return windowIsOpen
        default:
            return true
        }
    }
}
