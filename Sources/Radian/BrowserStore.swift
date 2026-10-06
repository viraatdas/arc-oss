import AppKit
import Observation
import RadianCore
import SwiftUI
import WebKit

struct CommandBarRequest: Identifiable, Equatable {
    enum Mode {
        /// Whatever is chosen opens in a new tab.
        case newTab
        /// Whatever is chosen replaces the page in `targetTabID`.
        case currentTab
        /// Whatever is chosen opens beside the selected tab.
        case splitPane
    }

    let id = UUID()
    var mode: Mode
    var initialText: String
    /// The tab a `.currentTab` request navigates: whichever pane had focus when the bar opened.
    var targetTabID: UUID?
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var symbol: String
}

/// Something irreversible waiting for the user to confirm it.
enum PendingDeletion: Identifiable, Equatable {
    case space(UUID)
    case folder(UUID)

    var id: UUID {
        switch self {
        case .space(let id), .folder(let id): id
        }
    }
}

/// A problem with the saved state that the user needs to hear about at launch.
enum StateNotice {
    /// The state file could not be read. It was kept at this address and Radian started fresh.
    case unreadable(URL)
    /// The state file came from a newer version of Radian. A copy was kept before using it.
    case newerVersion(backup: URL?)
}

/// What ⇧⌘T can bring back.
private enum ClosedTab {
    /// An unpinned tab, now this archive entry.
    case archived(UUID)
    /// A pinned tab or favorite that was unloaded and is still in the sidebar.
    case unloaded(UUID)
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
    var findBarTabID: UUID?
    /// Bumped to ask an open find bar to take focus again.
    private(set) var findFocusRequest = 0
    var editingSpaceID: UUID?
    var isArchivePresented = false
    var pendingDeletion: PendingDeletion?
    /// The sidebar's width while it is being dragged. Saved only when the drag ends.
    private(set) var liveSidebarWidth: CGFloat?
    private(set) var toast: Toast?
    /// The edge the incoming space slides in from.
    private(set) var spaceTransitionEdge: Edge = .trailing
    /// Still images shown in place of live pages. Only snapshot mode sets these, so that a page
    /// and the chrome drawn over it can be captured in one pass.
    private(set) var pageStills: [UUID: NSImage] = [:]

    let favicons: FaviconStore
    let downloads = DownloadCenter()
    /// True when there was no saved state at launch, as opposed to state that could not be read.
    let isFirstLaunch: Bool
    /// Set when the saved state needed attention at launch; the app delegate tells the user.
    let stateNotice: StateNotice?

    /// Sites allowed to download files during this session.
    @ObservationIgnored var downloadHosts: Set<String> = []
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private let stateFile: JSONFileStore<BrowserState>
    @ObservationIgnored private let historyFile: JSONFileStore<BrowsingHistory>
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isHistoryDirty = false
    @ObservationIgnored private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    @ObservationIgnored private var archiveTimer: Timer?
    @ObservationIgnored private var closedTabs: [ClosedTab] = []

    init(directory: URL = AppPaths.dataDirectory()) {
        stateFile = JSONFileStore(url: directory.appendingPathComponent("state.json"))
        historyFile = JSONFileStore(url: directory.appendingPathComponent("history.json"))
        favicons = FaviconStore(directory: directory.appendingPathComponent("favicons", isDirectory: true))

        var state: BrowserState
        var notice: StateNotice?
        switch stateFile.loadOrSetAside() {
        case .loaded(let loaded):
            state = loaded
            if loaded.schemaVersion > BrowserState.currentSchemaVersion {
                // Whatever this version does not understand would be lost on the next save.
                notice = .newerVersion(backup: stateFile.backUp(suffix: "from-newer-version"))
                state.schemaVersion = BrowserState.currentSchemaVersion
            }
            isFirstLaunch = false
        case .missing:
            state = .fresh()
            isFirstLaunch = true
        case .setAside(let location):
            state = .fresh()
            notice = .unreadable(location)
            isFirstLaunch = false
        }
        state.repair()
        self.state = state
        stateNotice = notice
        history = historyFile.loadOrSetAside().value ?? BrowsingHistory()
        downloads.report = { [weak self] text, symbol in self?.showToast(text, symbol: symbol) }
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
    var sidebarWidth: CGFloat { liveSidebarWidth ?? CGFloat(state.settings.sidebarWidth) }

    /// The tab page commands act on: the split pane holding keyboard focus, else the selected tab.
    var focusedTabID: UUID? {
        if let split = currentSpace.splitTabID, let webView = sessions[split]?.webView,
           let responder = window?.firstResponder as? NSView, responder.isDescendant(of: webView) {
            return split
        }
        return selectedTabID
    }

    var focusedSession: TabSession? { focusedTabID.flatMap { sessions[$0] } }

    /// Whether the tab is in one of the current space's panes.
    func isOnScreen(_ id: UUID) -> Bool {
        currentSpace.selectedTabID == id || currentSpace.splitTabID == id
    }

    /// Whether the user can actually see the tab right now: on screen, in a window that is open.
    func isShowing(_ id: UUID) -> Bool {
        isOnScreen(id) && window?.isVisible == true
    }

    /// The session showing a page dialog in this sheet window, if any.
    func session(presentingDialogIn sheet: NSWindow) -> TabSession? {
        sessions.values.first { $0.dialogWindow === sheet }
    }

    // MARK: - Persistence

    /// Every change to persisted state goes through here so that it is saved.
    @discardableResult
    private func mutate<Result>(_ body: (inout BrowserState) -> Result) -> Result {
        let result = body(&state)
        scheduleSave()
        return result
    }

    /// Saves shortly after the first unsaved change. Later changes ride along with that save
    /// rather than pushing it back, so a page that never stops changing cannot postpone saving.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
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
        // Pages may open windows only in response to a click, never on a timer or on load.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
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
        pageStills[id] = nil
    }

    private func wakeVisibleTabs() {
        if let id = currentSpace.selectedTabID { ensureSession(for: id) }
        if let id = currentSpace.splitTabID { ensureSession(for: id) }
    }

    func focusWebContent(_ id: UUID? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.commandBar == nil, self.renamingItemID == nil,
                  let webView = (id.flatMap { self.sessions[$0] } ?? self.selectedSession)?.webView,
                  webView.window != nil
            else { return }
            self.window?.makeFirstResponder(webView)
        }
    }

    /// The window was closed (it stays alive, hidden). Nothing should keep playing behind it.
    func windowDidHide() {
        for session in sessions.values {
            session.webView.setAllMediaPlaybackSuspended(true)
        }
    }

    func windowDidShow() {
        for session in sessions.values {
            session.webView.setAllMediaPlaybackSuspended(false)
        }
    }

    // MARK: - Tabs

    func select(_ id: UUID) {
        guard mutate({ $0.select(id) }) else { return }
        ensureSession(for: id)
        if findBarTabID != id { findBarTabID = nil }
        focusWebContent(id)
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
    /// WebKit requires the new view to be built from the configuration it hands over, which ties
    /// it to the opener's profile, so the tab opens in the opener's space. It comes to the front
    /// only if the opener is on screen.
    func openPopupTab(configuration: WKWebViewConfiguration, url: URL?, openedBy opener: UUID) -> TabSession? {
        guard let address = state.address(of: opener) else { return nil }
        let spaceID = address.spaceID ?? state.currentSpaceID
        let item = SidebarItem.tab(url: url ?? URL(string: "about:blank")!)
        guard mutate({ $0.insert(item, at: MoveDestination(spaceID: spaceID, section: .tabs, placement: .start)) }) else {
            return nil
        }
        let session = TabSession(id: item.id, configuration: configuration, store: self)
        sessions[item.id] = session
        if isShowing(opener) {
            select(item.id)
        }
        return session
    }

    /// Opens an address chosen in the command bar, or one handed over by another app.
    func open(_ url: URL, mode: CommandBarRequest.Mode, target: UUID? = nil) {
        guard BrowserStore.isWebURL(url) else {
            NSWorkspace.shared.open(url)
            return
        }
        switch mode {
        case .currentTab:
            if let id = target ?? focusedTabID, let session = ensureSession(for: id) {
                session.load(url)
                focusWebContent(id)
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
        let wasSelected = currentSpace.selectedTabID == id
        guard let outcome = mutate({ $0.close(id) }) else { return }
        discardSession(id)
        switch outcome {
        case .archived(let entryID): closedTabs.append(.archived(entryID))
        case .unloaded: closedTabs.append(.unloaded(id))
        case .removed: break
        }
        if closedTabs.count > 50 { closedTabs.removeFirst(closedTabs.count - 50) }
        selectNextTab(ifNoneAfterClosing: id, wasSelected: wasSelected)
    }

    func closeFocusedTab() {
        if let id = focusedTabID {
            closeTab(id)
        } else {
            window?.performClose(nil)
        }
    }

    /// Removes a tab whose only purpose was a download, as other browsers do. Unlike closing, it
    /// leaves nothing in the archive: there was never a page to come back to.
    func discardDownloadTab(_ id: UUID) {
        guard state.address(of: id)?.section == .tabs else { return }
        let wasSelected = currentSpace.selectedTabID == id
        discardSession(id)
        mutate { state in
            state.removeItem(withID: id)
            state.repairSelections()
        }
        selectNextTab(ifNoneAfterClosing: id, wasSelected: wasSelected)
    }

    private func selectNextTab(ifNoneAfterClosing closed: UUID, wasSelected: Bool) {
        if wasSelected, currentSpace.selectedTabID == nil, let next = tabToSelect(afterClosing: closed) {
            select(next)
        } else {
            wakeVisibleTabs()
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

    /// Brings back the most recently closed tab, skipping any that have since gone for good.
    func reopenClosedTab() {
        while let last = closedTabs.popLast() {
            switch last {
            case .archived(let entryID) where state.archive.contains(where: { $0.id == entryID }):
                restoreArchived(entryID)
                return
            case .unloaded(let id) where state.item(withID: id) != nil:
                select(id)
                return
            default:
                continue
            }
        }
        // Nothing closed in this session: offer the newest archive entry instead.
        if let entry = state.archive.first {
            restoreArchived(entry.id)
        }
    }

    func restoreArchived(_ entryID: UUID) {
        guard let id = mutate({ $0.restoreArchived(entryID) }) else { return }
        select(id)
    }

    func clearArchive() {
        mutate { $0.archive.removeAll() }
        closedTabs.removeAll { if case .archived = $0 { return true } else { return false } }
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

    @discardableResult
    func move(_ id: UUID, to destination: MoveDestination) -> Bool {
        let before = state.address(of: id)
        guard mutate({ $0.move(id, to: destination) }) else { return false }
        if before?.profileID != state.address(of: id)?.profileID, let item = state.item(withID: id) {
            // A web view is bound to its profile's cookie jar, so it cannot follow the tab across.
            [item].allTabs.forEach { discardSession($0.id) }
        }
        wakeVisibleTabs()
        return true
    }

    /// Where an item dropped on a space's icon goes: open tabs stay open tabs, everything else
    /// is pinned. Nil when it is already in that space.
    func destination(forDropping id: UUID, onSpace spaceID: UUID) -> MoveDestination? {
        guard let address = state.address(of: id), address.spaceID != spaceID else { return nil }
        if address.section == .tabs {
            return MoveDestination(spaceID: spaceID, section: .tabs, placement: .start)
        }
        return MoveDestination(spaceID: spaceID, section: .pinned, placement: .end)
    }

    func moveToSpace(_ id: UUID, spaceID: UUID) {
        guard let destination = destination(forDropping: id, onSpace: spaceID),
              let name = state.space(withID: spaceID)?.name,
              move(id, to: destination)
        else { return }
        showToast("Moved to \(name)", symbol: "arrow.right.circle.fill")
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
                } else if trimmed.isEmpty || trimmed == item.title {
                    // An empty or unchanged name keeps following the page's own title.
                    item.customTitle = nil
                } else {
                    item.customTitle = trimmed
                }
            }
        }
        renamingItemID = nil
        focusWebContent()
    }

    /// Removes a pinned tab, favorite or folder. Its tabs go to the archive, so this can be undone
    /// from there.
    func deleteItem(_ id: UUID) {
        guard let item = state.item(withID: id) else { return }
        [item].allTabs.forEach { discardSession($0.id) }
        mutate { $0.deleteItem(withID: id) }
        wakeVisibleTabs()
    }

    /// Deletes an empty folder straight away, and asks first about one with tabs in it.
    func requestDeleteFolder(_ id: UUID) {
        guard let folder = state.item(withID: id), folder.isFolder else { return }
        if folder.children.allTabs.isEmpty {
            deleteItem(id)
        } else {
            pendingDeletion = .folder(id)
        }
    }

    func requestDeleteSpace(_ id: UUID) {
        guard state.spaces.count > 1, state.space(withID: id) != nil else { return }
        pendingDeletion = .space(id)
    }

    /// The wording of the confirmation for a pending deletion.
    func describe(_ deletion: PendingDeletion) -> (title: String, message: String, action: String) {
        func tabs(_ count: Int) -> String { count == 1 ? "Its tab" : "Its \(count) tabs" }
        switch deletion {
        case .space(let id):
            let space = state.space(withID: id)
            let count = (space?.pinned.allTabs.count ?? 0) + (space?.tabs.count ?? 0)
            let detail = count == 0 ? "It has no tabs." : "\(tabs(count)) will move to the archive."
            return ("Delete the space “\(space?.name ?? "")”?", detail, "Delete Space")
        case .folder(let id):
            let folder = state.item(withID: id)
            let count = folder?.children.allTabs.count ?? 0
            return ("Delete the folder “\(folder?.displayTitle ?? "")”?", "\(tabs(count)) will move to the archive.", "Delete Folder")
        }
    }

    func confirm(_ deletion: PendingDeletion) {
        pendingDeletion = nil
        switch deletion {
        case .space(let id): deleteSpace(id)
        case .folder(let id): deleteItem(id)
        }
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

    /// Follows a resize drag. Only the final width is saved, when `commitSidebarWidth` is called.
    func setSidebarWidth(_ width: CGFloat) {
        liveSidebarWidth = min(max(width, 200), 440)
    }

    func commitSidebarWidth() {
        guard let width = liveSidebarWidth else { return }
        mutate { $0.settings.sidebarWidth = Double(width) }
        liveSidebarWidth = nil
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
        mutate { $0.showSpace(id) }
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

    /// Deletes a space without asking. Its tabs go to the archive. Menus use `requestDeleteSpace`.
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

    func renameProfile(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutate { state in
            guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
            state.profiles[index].name = trimmed
        }
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
        guard selectedTabID != nil else {
            select(id)
            return
        }
        guard mutate({ $0.setSplit(id) }) else { return }
        ensureSession(for: id)
    }

    func closeSplit() {
        mutate { $0.setSplit(nil) }
        focusWebContent()
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
        let target = mode == .currentTab ? focusedTabID : nil
        let currentURL = target.flatMap { state.item(withID: $0)?.url?.absoluteString }
        commandBar = CommandBarRequest(mode: mode, initialText: initialText ?? currentURL ?? "", targetTabID: target)
    }

    func requestFindBar() {
        guard let id = focusedTabID else { return }
        findBarTabID = id
        findFocusRequest += 1
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

    /// A tab's page process died while it was off screen, usually because macOS reclaimed its
    /// memory. The tab goes to sleep and reloads when it is next shown, as if it had never loaded.
    func sessionDidCrashOffScreen(_ id: UUID) {
        discardSession(id)
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
        if let window {
            NSAccessibility.post(
                element: window,
                notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }
}
