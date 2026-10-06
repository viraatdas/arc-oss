import AppKit
import RadianCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = BrowserStore()
    private var windowController: BrowserWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(target: self)
        let controller = BrowserWindowController(store: store)
        windowController = controller
        controller.showWindow(nil)
        store.start()
        NSApp.activate(ignoringOtherApps: true)

        if store.isFirstLaunch {
            offerArcImport()
        }
    }

    /// Links clicked in other apps arrive here when Radian is the default browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            store.open(url, mode: .newTab)
        }
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            windowController?.showWindow(nil)
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
            keyWindow.performClose(sender)
        } else if store.commandBar != nil {
            store.dismissCommandBar()
        } else {
            store.closeSelectedTab()
        }
    }

    @objc func reopenClosedTab(_ sender: Any?) { store.reopenClosedTab() }
    @objc func newFolder(_ sender: Any?) { store.newFolder() }

    // MARK: - Edit

    @objc func findInPage(_ sender: Any?) {
        store.findBarTabID = store.selectedTabID
    }

    @objc func copyLink(_ sender: Any?) {
        if let id = store.selectedTabID { store.copyLink(of: id) }
    }

    // MARK: - View

    @objc func toggleSidebar(_ sender: Any?) { store.toggleSidebar() }
    @objc func reloadPage(_ sender: Any?) { store.selectedSession?.reload() }
    @objc func stopLoading(_ sender: Any?) { store.selectedSession?.stop() }
    @objc func zoomIn(_ sender: Any?) { store.selectedSession?.zoom(by: 0.1) }
    @objc func zoomOut(_ sender: Any?) { store.selectedSession?.zoom(by: -0.1) }
    @objc func actualSize(_ sender: Any?) { store.selectedSession?.resetZoom() }
    @objc func toggleSplit(_ sender: Any?) { store.toggleSplit() }

    // MARK: - Tabs

    @objc func goBack(_ sender: Any?) { store.selectedSession?.goBack() }
    @objc func goForward(_ sender: Any?) { store.selectedSession?.goForward() }
    @objc func nextTab(_ sender: Any?) { store.selectAdjacentTab(offset: 1) }
    @objc func previousTab(_ sender: Any?) { store.selectAdjacentTab(offset: -1) }

    @objc func togglePin(_ sender: Any?) {
        if let id = store.selectedTabID { store.togglePin(id) }
    }

    @objc func addToFavorites(_ sender: Any?) {
        if let id = store.selectedTabID { store.addToFavorites(id) }
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
            + "and favorites. Arc itself is not changed, and you can do this later from the File menu."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.importFromArc(nil) }
        }
    }

    private func present(_ alert: NSAlert) {
        if let window = windowController?.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func showWindow() {
        windowController?.showWindow(nil)
    }
}
