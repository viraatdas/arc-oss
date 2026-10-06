import AppKit
import Observation
import RadianCore
import SwiftUI
import WebKit

struct CommandBarRequest: Identifiable, Equatable {
    enum Mode {
        /// Whatever is chosen opens in a new tab.
        case newTab
        /// Whatever is chosen replaces the page in the selected tab.
        case currentTab
        /// Whatever is chosen opens beside the selected tab.
        case splitPane
    }

    let id = UUID()
    var mode: Mode
    var initialText: String
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var symbol: String
}

/// The single source of truth for the window: persisted state, live web views and transient UI state.
@MainActor
@Observable
final class BrowserStore {
    private(set) var state: BrowserState
    private(set) var history: BrowsingHistory
    /// Live web views, keyed by tab id. A tab without a session is asleep: it is listed in the
    /// sidebar but has no page loaded.
    private(set) var sessions: [UUID: TabSession] = [:]

    var isSidebarVisible = true
    var commandBar: CommandBarRequest?
    var renamingItemID: UUID?
    var draggingItemID: UUID?
    var findBarTabID: UUID?
    var editingSpaceID: UUID?
    var isArchivePresented = false
    private(set) var toast: Toast?
    /// The edge the incoming space slides in from.
    private(set) var spaceTransitionEdge: Edge = .trailing
    /// Still images shown in place of live pages. Only snapshot mode sets these, so that a page
    /// and the chrome drawn over it can be captured in one pass.
    private(set) var pageStills: [UUID: NSImage] = [:]

    let favicons: FaviconStore
    /// True when no saved state existed at launch.
    let isFirstLaunch: Bool

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private let stateFile: JSONFileStore<BrowserState>
    @ObservationIgnored private let historyFile: JSONFileStore<BrowsingHistory>
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isHistoryDirty = false
    @ObservationIgnored private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    @ObservationIgnored private var archiveTimer: Timer?

    init(directory: URL = AppPaths.dataDirectory()) {
        stateFile = JSONFileStore(url: directory.appendingPathComponent("state.json"))
        historyFile = JSONFileStore(url: directory.appendingPathComponent("history.json"))
        favicons = FaviconStore(directory: directory.appendingPathComponent("favicons", isDirectory: true))

        let loaded = stateFile.loadOrQuarantine()
        isFirstLaunch = loaded == nil
        var state = loaded ?? .fresh()
        state.repair()
        self.state = state
        history = historyFile.loadOrQuarantine() ?? BrowsingHistory()
    }

    /// Called once the window exists: wakes the tabs that are on screen and starts housekeeping.
    func start() {
        sweepArchive()
        wakeVisibleTabs()
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweepArchive() }
        }
    }

    // MARK: - Derived state

    var currentSpace: Space { state.currentSpace }
    var selectedTabID: UUID? { currentSpace.selectedTabID }
    var selectedItem: SidebarItem? { selectedTabID.flatMap { state.item(withID: $0) } }
    var selectedSession: TabSession? { selectedTabID.flatMap { sessions[$0] } }
    var splitSession: TabSession? { currentSpace.splitTabID.flatMap { sessions[$0] } }
    var isSplit: Bool { currentSpace.splitTabID != nil }
    var sidebarWidth: CGFloat { CGFloat(state.settings.sidebarWidth) }

    func isOnScreen(_ id: UUID) -> Bool {
        currentSpace.selectedTabID == id || currentSpace.splitTabID == id
    }

    // MARK: - Persistence

    /// Every change to persisted state goes through here so that it is saved.
    @discardableResult
    private func mutate<Result>(_ body: (inout BrowserState) -> Result) -> Result {
        let result = body(&state)
        scheduleSave()
        return result
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            try stateFile.save(state)
            if isHistoryDirty {
                try historyFile.save(history)
                isHistoryDirty = false
            }
        } catch {
            NSLog("Radian: could not save state: %@", error.localizedDescription)
        }
    }

    // MARK: - Web views

    static func isWebURL(_ url: URL) -> Bool {
        ["http", "https", "file", "about", "data", "blob"].contains(url.scheme?.lowercased() ?? "")
    }

    /// WebKit reports a bare "AppleWebKit" agent, which many sites treat as an unknown browser.
    /// Appending the Safari token that matches this OS gets Radian the same pages Safari gets.
    private static let userAgentSuffix: String = {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let safari = major >= 26 ? major : major + 3
        return "Version/\(safari).0 Safari/605.1.15"
    }()

    func makeConfiguration(profileID: UUID) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore(forProfile: profileID)
        configuration.applicationNameForUserAgent = BrowserStore.userAgentSuffix
        configuration.preferences.isElementFullscreenEnabled = true
        // Enables "Inspect Element" in the page's context menu.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        return configuration
    }

    /// Each profile gets its own cookie jar and storage, which is what keeps profiles separate.
    private func dataStore(forProfile id: UUID) -> WKWebsiteDataStore {
        if let existing = dataStores[id] { return existing }
        let store = WKWebsiteDataStore(forIdentifier: id)
        dataStores[id] = store
        return store
    }

    @discardableResult
    private func ensureSession(for id: UUID) -> TabSession? {
        if let existing = sessions[id] { return existing }
        guard let item = state.item(withID: id), !item.isFolder, let address = state.address(of: id) else {
            return nil
        }
        let session = TabSession(id: id, configuration: makeConfiguration(profileID: address.profileID), store: self)
        sessions[id] = session
        if let url = item.url ?? item.homeURL {
            session.load(url)
        }
        return session
    }

    private func discardSession(_ id: UUID) {
        sessions[id]?.teardown()
        sessions[id] = nil
        if findBarTabID == id { findBarTabID = nil }
    }

    private func wakeVisibleTabs() {
        if let id = currentSpace.selectedTabID { ensureSession(for: id) }
        if let id = currentSpace.splitTabID { ensureSession(for: id) }
    }

    func focusWebContent() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.commandBar == nil, self.renamingItemID == nil,
                  let webView = self.selectedSession?.webView, webView.window != nil
            else { return }
            self.window?.makeFirstResponder(webView)
        }
    }

    // MARK: - Tabs

    func select(_ id: UUID) {
        guard let item = state.item(withID: id), !item.isFolder, let address = state.address(of: id) else { return }
        // Favorites belong to a profile, not a space, so they open in whichever space is showing.
        let spaceID = address.spaceID ?? state.currentSpaceID
        mutate { state in
            guard let index = state.spaces.firstIndex(where: { $0.id == spaceID }) else { return }
            if state.spaces[index].splitTabID == id {
                // The tab is already in the other pane: swap the panes instead of showing it twice.
                state.spaces[index].splitTabID = state.spaces[index].selectedTabID
            }
            state.spaces[index].selectedTabID = id
            state.currentSpaceID = spaceID
            state.updateItem(withID: id) { $0.lastActiveAt = Date() }
        }
        ensureSession(for: id)
        if findBarTabID != id { findBarTabID = nil }
        focusWebContent()
    }

    @discardableResult
    func openTab(url: URL, inBackground: Bool = false, title: String? = nil) -> UUID {
        let item = SidebarItem.tab(url: url, title: title)
        mutate { state in
            state.insert(item, at: MoveDestination(spaceID: state.currentSpaceID, section: .tabs, placement: .start))
        }
        if inBackground {
            ensureSession(for: item.id)
        } else {
            select(item.id)
        }
        return item.id
    }

    /// Adopts a web view that a page asked for with `window.open` or a `target=_blank` link.
    /// WebKit requires the new view to be built from the configuration it hands over.
    func openPopupTab(configuration: WKWebViewConfiguration, url: URL?) -> TabSession {
        let item = SidebarItem.tab(url: url ?? URL(string: "about:blank")!)
        mutate { state in
            state.insert(item, at: MoveDestination(spaceID: state.currentSpaceID, section: .tabs, placement: .start))
        }
        let session = TabSession(id: item.id, configuration: configuration, store: self)
        sessions[item.id] = session
        select(item.id)
        return session
    }

    /// Opens an address chosen in the command bar, or one handed over by another app.
    func open(_ url: URL, mode: CommandBarRequest.Mode) {
        guard BrowserStore.isWebURL(url) else {
            NSWorkspace.shared.open(url)
            return
        }
        switch mode {
        case .currentTab:
            if let id = selectedTabID, let session = ensureSession(for: id) {
                session.load(url)
                focusWebContent()
            } else {
                openTab(url: url)
            }
        case .splitPane where selectedTabID != nil:
            openInSplit(openTab(url: url, inBackground: true))
        case .newTab, .splitPane:
            openTab(url: url)
        }
    }

    func freezePages(_ stills: [UUID: NSImage]) {
        pageStills = stills
    }

    func closeTab(_ id: UUID) {
        guard let address = state.address(of: id) else { return }
        let wasSelected = currentSpace.selectedTabID == id
        discardSession(id)
        mutate { state in
            for index in state.spaces.indices {
                if state.spaces[index].splitTabID == id {
                    state.spaces[index].splitTabID = nil
                }
                if state.spaces[index].selectedTabID == id {
                    state.spaces[index].selectedTabID = state.spaces[index].splitTabID
                    state.spaces[index].splitTabID = nil
                }
            }
            switch address.section {
            case .tabs:
                if let removed = state.removeItem(withID: id), let spaceID = address.spaceID {
                    state.archive(removed, spaceID: spaceID)
                }
            case .pinned, .favorites:
                // Pinned tabs are never removed by closing. They go back to sleep at their home.
                state.updateItem(withID: id) { $0.url = $0.homeURL ?? $0.url }
            }
        }
        if wasSelected, currentSpace.selectedTabID == nil, let next = tabToSelect(afterClosing: id) {
            select(next)
        } else {
            wakeVisibleTabs()
        }
    }

    func closeSelectedTab() {
        if let id = selectedTabID {
            closeTab(id)
        } else {
            window?.performClose(nil)
        }
    }

    /// After a close, prefer the tab the user was on most recently among those still loaded.
    private func tabToSelect(afterClosing closed: UUID) -> UUID? {
        if let live = mostRecentLiveTab(excluding: [closed]) { return live }
        return currentSpace.tabs.first { $0.id != closed }?.id
    }

    private func mostRecentLiveTab(excluding excluded: Set<UUID>) -> UUID? {
        let space = currentSpace
        let candidates = state.favorites(forSpace: space.id).allTabs + space.pinned.allTabs + space.tabs.allTabs
        return candidates
            .filter { !excluded.contains($0.id) && sessions[$0.id] != nil }
            .max { $0.lastActiveAt < $1.lastActiveAt }?
            .id
    }

    func reopenClosedTab() {
        guard let entry = state.archive.first else { return }
        restoreArchived(entry.id)
    }

    func restoreArchived(_ id: UUID) {
        guard let entry = state.archive.first(where: { $0.id == id }) else { return }
        let spaceID = state.space(withID: entry.spaceID) != nil ? entry.spaceID : state.currentSpaceID
        let item = SidebarItem.tab(url: entry.url, title: entry.title)
        mutate { state in
            state.archive.removeAll { $0.id == id }
            state.insert(item, at: MoveDestination(spaceID: spaceID, section: .tabs, placement: .start))
        }
        select(item.id)
    }

    func clearArchive() {
        mutate { $0.archive.removeAll() }
    }

    private func sweepArchive() {
        var copy = state
        let archived = copy.archiveStaleTabs()
        guard !archived.isEmpty else { return }
        archived.forEach(discardSession)
        state = copy
        scheduleSave()
    }

    /// Moves between tabs in the order the sidebar shows them, wrapping at the ends.
    func selectAdjacentTab(offset: Int) {
        let tabs = state.visibleTabs(inSpace: state.currentSpaceID)
        guard !tabs.isEmpty else { return }
        guard let current = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            select(tabs[0].id)
            return
        }
        select(tabs[(current + offset + tabs.count) % tabs.count].id)
    }

    /// ⌘1…⌘9: the Nth tab counting from the top of the sidebar.
    func selectTab(atPosition position: Int) {
        let tabs = state.visibleTabs(inSpace: state.currentSpaceID)
        guard tabs.indices.contains(position) else { return }
        select(tabs[position].id)
    }

    func copyLink(of id: UUID) {
        guard let url = state.item(withID: id)?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showToast("Link copied", symbol: "link")
    }

    // MARK: - Sidebar structure

    func move(_ id: UUID, to destination: MoveDestination) {
        let before = state.address(of: id)
        guard mutate({ $0.move(id, to: destination) }) else { return }
        if before?.profileID != state.address(of: id)?.profileID, let item = state.item(withID: id) {
            // A web view is bound to its profile's cookie jar, so it cannot follow the tab across.
            [item].allTabs.forEach { discardSession($0.id) }
        }
        wakeVisibleTabs()
    }

    func togglePin(_ id: UUID) {
        guard let address = state.address(of: id) else { return }
        let spaceID = address.spaceID ?? state.currentSpaceID
        if address.section == .tabs {
            move(id, to: MoveDestination(spaceID: spaceID, section: .pinned, placement: .end))
        } else {
            move(id, to: MoveDestination(spaceID: spaceID, section: .tabs, placement: .start))
        }
    }

    func addToFavorites(_ id: UUID) {
        move(id, to: MoveDestination(spaceID: state.currentSpaceID, section: .favorites, placement: .end))
    }

    func newFolder() {
        let folder = SidebarItem.folder(name: "New Folder")
        mutate { state in
            state.insert(folder, at: MoveDestination(spaceID: state.currentSpaceID, section: .pinned, placement: .end))
        }
        renamingItemID = folder.id
    }

    func toggleFolder(_ id: UUID) {
        mutate { state in
            state.updateItem(withID: id) { $0.isExpanded.toggle() }
        }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        mutate { state in
            state.updateItem(withID: id) { item in
                if item.isFolder {
                    if !trimmed.isEmpty { item.title = trimmed }
                } else {
                    // Clearing a tab's name goes back to showing the page title.
                    item.customTitle = trimmed.isEmpty ? nil : trimmed
                }
            }
        }
        renamingItemID = nil
    }

    /// Deletes a pinned tab, favorite or folder (with everything in it) outright.
    func removeItem(_ id: UUID) {
        guard let item = state.item(withID: id) else { return }
        [item].allTabs.forEach { discardSession($0.id) }
        mutate { state in
            state.removeItem(withID: id)
            state.repairSelections()
        }
        wakeVisibleTabs()
    }

    /// Returns a pinned tab to the address it was pinned at.
    func resetToHome(_ id: UUID) {
        guard let home = state.item(withID: id)?.homeURL else { return }
        mutate { state in
            state.updateItem(withID: id) { $0.url = home }
        }
        sessions[id]?.load(home)
    }

    /// Makes wherever a pinned tab is now its new home.
    func adoptCurrentURLAsHome(_ id: UUID) {
        mutate { state in
            state.updateItem(withID: id) { $0.homeURL = $0.url ?? $0.homeURL }
        }
    }

    func setSidebarWidth(_ width: CGFloat) {
        mutate { $0.settings.sidebarWidth = Double(min(max(width, 200), 440)) }
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
        applyWindowChrome()
    }

    /// The traffic lights sit in the sidebar, so they go away with it.
    func applyWindowChrome() {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = !isSidebarVisible
        }
    }

    // MARK: - Spaces

    func switchSpace(to id: UUID) {
        guard id != state.currentSpaceID, let target = state.spaces.firstIndex(where: { $0.id == id }) else { return }
        spaceTransitionEdge = target > state.currentSpaceIndex ? .trailing : .leading
        mutate { $0.currentSpaceID = id }
        findBarTabID = nil
        wakeVisibleTabs()
        focusWebContent()
    }

    func cycleSpace(by delta: Int) {
        let target = state.currentSpaceIndex + delta
        guard state.spaces.indices.contains(target) else { return }
        switchSpace(to: state.spaces[target].id)
    }

    func selectSpace(atPosition position: Int) {
        guard state.spaces.indices.contains(position) else { return }
        switchSpace(to: state.spaces[position].id)
    }

    func newSpace() {
        let space = Space(
            name: "New Space",
            icon: .symbol("sparkles"),
            theme: SpaceTheme.presets[state.spaces.count % SpaceTheme.presets.count],
            profileID: currentSpace.profileID
        )
        mutate { $0.spaces.append(space) }
        switchSpace(to: space.id)
        editingSpaceID = space.id
    }

    func updateSpace(_ id: UUID, _ body: (inout Space) -> Void) {
        mutate { state in
            guard let index = state.spaces.firstIndex(where: { $0.id == id }) else { return }
            body(&state.spaces[index])
        }
    }

    func deleteSpace(_ id: UUID) {
        guard let removedTabs = mutate({ $0.removeSpace(withID: id) }) else { return }
        removedTabs.forEach { discardSession($0.id) }
        if editingSpaceID == id { editingSpaceID = nil }
        wakeVisibleTabs()
    }

    /// Moves a space to another profile. Its tabs reload, because they now use different cookies.
    func setProfile(_ profileID: UUID, forSpace spaceID: UUID) {
        guard let space = state.space(withID: spaceID), space.profileID != profileID,
              state.profiles.contains(where: { $0.id == profileID })
        else { return }
        (space.pinned.allTabs + space.tabs.allTabs).forEach { discardSession($0.id) }
        mutate { state in
            guard let index = state.spaces.firstIndex(where: { $0.id == spaceID }) else { return }
            state.spaces[index].profileID = profileID
            state.repairSelections()
        }
        wakeVisibleTabs()
    }

    @discardableResult
    func newProfile() -> UUID {
        let profile = Profile(name: "Profile \(state.profiles.count + 1)")
        mutate { $0.profiles.append(profile) }
        return profile.id
    }

    // MARK: - Split view

    func openInSplit(_ id: UUID) {
        guard let item = state.item(withID: id), !item.isFolder else { return }
        guard let selected = selectedTabID else {
            select(id)
            return
        }
        guard id != selected, state.visibleTabsIncludingCollapsed(inSpace: state.currentSpaceID).contains(id) else { return }
        mutate { $0.spaces[$0.currentSpaceIndex].splitTabID = id }
        ensureSession(for: id)
    }

    func closeSplit() {
        mutate { $0.spaces[$0.currentSpaceIndex].splitTabID = nil }
    }

    /// Closes the split, or asks what to open beside the current tab.
    func toggleSplit() {
        if isSplit {
            closeSplit()
        } else if selectedTabID != nil {
            commandBar = CommandBarRequest(mode: .splitPane, initialText: "")
        }
    }

    // MARK: - Command bar

    func presentCommandBar(_ mode: CommandBarRequest.Mode, initialText: String? = nil) {
        // With no tab selected there is nothing to replace or sit beside, so everything is a new tab.
        guard selectedItem != nil else {
            commandBar = CommandBarRequest(mode: .newTab, initialText: initialText ?? "")
            return
        }
        let currentURL = mode == .currentTab ? selectedItem?.url?.absoluteString : nil
        commandBar = CommandBarRequest(mode: mode, initialText: initialText ?? currentURL ?? "")
    }

    func dismissCommandBar() {
        commandBar = nil
        focusWebContent()
    }

    // MARK: - Callbacks from web views

    func sessionDidChange(_ id: UUID, title: String?, url: URL?) {
        guard let item = state.item(withID: id) else { return }
        var newTitle = item.title
        var newURL = item.url
        // Titles go blank for a moment while a page loads; keep the old one until the new one lands.
        if let title, !title.isEmpty { newTitle = title }
        if let url, url.absoluteString != "about:blank" || item.url == nil { newURL = url }
        guard newTitle != item.title || newURL != item.url else { return }
        mutate { state in
            state.updateItem(withID: id) { item in
                item.title = newTitle
                item.url = newURL
            }
        }
    }

    func sessionDidFinish(_ id: UUID, title: String, url: URL) {
        history.record(url: url, title: title)
        isHistoryDirty = true
        scheduleSave()
    }

    // MARK: - Import

    func importFromArc(at url: URL) throws -> (stats: ArcImportResult.Stats, summary: ArcMergeSummary) {
        let imported = try ArcImporter.importSidebar(at: url)
        let summary = mutate { $0.merge(imported) }
        if let first = summary.addedSpaceIDs.first {
            switchSpace(to: first)
        }
        return (imported.stats, summary)
    }

    // MARK: - Settings

    func setSearchEngine(_ engine: SearchEngine) {
        mutate { $0.settings.searchEngine = engine }
        showToast("Searching with \(engine.displayName)", symbol: "magnifyingglass")
    }

    func setArchiveAfterHours(_ hours: Double?) {
        mutate { $0.settings.archiveAfterHours = hours }
    }

    func showToast(_ text: String, symbol: String = "checkmark.circle.fill") {
        let toast = Toast(text: text, symbol: symbol)
        self.toast = toast
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }
}

extension BrowserState {
    /// Ids of every tab reachable from a space, including those inside collapsed folders.
    func visibleTabsIncludingCollapsed(inSpace spaceID: UUID) -> Set<UUID> {
        guard let space = space(withID: spaceID) else { return [] }
        return Set((favorites(forSpace: spaceID).allTabs + space.pinned.allTabs + space.tabs.allTabs).map(\.id))
    }
}
