import Foundation

public enum SidebarSection: String, Codable, Sendable {
    /// The grid at the top of the sidebar. Shared by every space on the same profile.
    case favorites
    case pinned
    case tabs
}

/// Where an item lives. Favorites belong to a profile rather than a space, so `spaceID` is nil for them.
public struct ItemAddress: Equatable, Sendable {
    public var section: SidebarSection
    public var spaceID: UUID?
    public var profileID: UUID
}

public struct MoveDestination: Equatable, Sendable {
    public var spaceID: UUID
    public var section: SidebarSection
    public var placement: Placement

    public init(spaceID: UUID, section: SidebarSection, placement: Placement) {
        self.spaceID = spaceID
        self.section = section
        self.placement = placement
    }
}

/// Everything Radian persists: profiles, spaces, their tabs, the archive and settings.
public struct BrowserState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    /// Large enough that one sweep of a big imported session cannot push older entries out.
    public static let archiveLimit = 2000

    public var schemaVersion: Int
    public var profiles: [Profile]
    public var spaces: [Space]
    public var currentSpaceID: UUID
    public var archive: [ArchivedTab]
    public var settings: Settings

    public init(
        profiles: [Profile],
        spaces: [Space],
        currentSpaceID: UUID,
        archive: [ArchivedTab] = [],
        settings: Settings = Settings()
    ) {
        self.schemaVersion = BrowserState.currentSchemaVersion
        self.profiles = profiles
        self.spaces = spaces
        self.currentSpaceID = currentSpaceID
        self.archive = archive
        self.settings = settings
    }

    /// The state a brand-new install starts from: one profile holding one empty space.
    public static func fresh() -> BrowserState {
        let profile = Profile(name: "Personal")
        let space = Space(name: "Personal", icon: .symbol("house.fill"), profileID: profile.id)
        return BrowserState(profiles: [profile], spaces: [space], currentSpaceID: space.id)
    }
}

// MARK: - Lookup

extension BrowserState {
    public var currentSpaceIndex: Int {
        spaces.firstIndex { $0.id == currentSpaceID } ?? 0
    }

    public var currentSpace: Space {
        spaces[currentSpaceIndex]
    }

    public func space(withID id: UUID) -> Space? {
        spaces.first { $0.id == id }
    }

    public func profile(forSpace spaceID: UUID) -> Profile? {
        guard let space = space(withID: spaceID) else { return nil }
        return profiles.first { $0.id == space.profileID }
    }

    /// Favorites shown in the given space.
    public func favorites(forSpace spaceID: UUID) -> [SidebarItem] {
        profile(forSpace: spaceID)?.favorites ?? []
    }

    public func address(of id: UUID) -> ItemAddress? {
        for space in spaces {
            if space.pinned.contains(itemWithID: id) {
                return ItemAddress(section: .pinned, spaceID: space.id, profileID: space.profileID)
            }
            if space.tabs.contains(itemWithID: id) {
                return ItemAddress(section: .tabs, spaceID: space.id, profileID: space.profileID)
            }
        }
        for profile in profiles where profile.favorites.contains(itemWithID: id) {
            return ItemAddress(section: .favorites, spaceID: nil, profileID: profile.id)
        }
        return nil
    }

    public func item(withID id: UUID) -> SidebarItem? {
        for space in spaces {
            if let found = space.pinned.item(withID: id) ?? space.tabs.item(withID: id) { return found }
        }
        for profile in profiles {
            if let found = profile.favorites.item(withID: id) { return found }
        }
        return nil
    }

    /// The tabs of a space in the order the sidebar draws them: favorites, pinned, then unpinned.
    public func visibleTabs(inSpace spaceID: UUID) -> [SidebarItem] {
        guard let space = space(withID: spaceID) else { return [] }
        return favorites(forSpace: spaceID).visibleTabs + space.pinned.visibleTabs + space.tabs.visibleTabs
    }
}

// MARK: - Mutation

extension BrowserState {
    @discardableResult
    public mutating func updateItem(withID id: UUID, _ body: (inout SidebarItem) -> Void) -> Bool {
        for index in spaces.indices {
            if spaces[index].pinned.updateItem(withID: id, body) { return true }
            if spaces[index].tabs.updateItem(withID: id, body) { return true }
        }
        for index in profiles.indices {
            if profiles[index].favorites.updateItem(withID: id, body) { return true }
        }
        return false
    }

    @discardableResult
    public mutating func removeItem(withID id: UUID) -> SidebarItem? {
        for index in spaces.indices {
            if let removed = spaces[index].pinned.removeItem(withID: id) { return removed }
            if let removed = spaces[index].tabs.removeItem(withID: id) { return removed }
        }
        for index in profiles.indices {
            if let removed = profiles[index].favorites.removeItem(withID: id) { return removed }
        }
        return nil
    }

    /// Inserts an item, adapting it to the section it lands in. Returns false if the destination
    /// does not exist or cannot hold the item (folders only live in the pinned section).
    @discardableResult
    public mutating func insert(_ item: SidebarItem, at destination: MoveDestination, now: Date = Date()) -> Bool {
        guard let spaceIndex = spaces.firstIndex(where: { $0.id == destination.spaceID }) else { return false }
        var item = item
        switch destination.section {
        case .favorites:
            guard !item.isFolder, destination.placement.folderID == nil,
                  let profileIndex = profiles.firstIndex(where: { $0.id == spaces[spaceIndex].profileID })
            else { return false }
            item.homeURL = item.homeURL ?? item.url
            return profiles[profileIndex].favorites.place(item, destination.placement)
        case .pinned:
            item.anchorTabs()
            return spaces[spaceIndex].pinned.place(item, destination.placement)
        case .tabs:
            guard !item.isFolder, destination.placement.folderID == nil else { return false }
            item.homeURL = nil
            // The archive clock starts when a tab arrives, not when it was last opened elsewhere.
            item.lastActiveAt = now
            return spaces[spaceIndex].tabs.place(item, destination.placement)
        }
    }

    /// Moves an item anywhere in the sidebar. All-or-nothing: on failure the state is unchanged.
    @discardableResult
    public mutating func move(_ id: UUID, to destination: MoveDestination, now: Date = Date()) -> Bool {
        guard let item = item(withID: id) else { return false }
        switch destination.placement {
        case .before(let target), .inFolder(let target):
            // Dropping an item onto itself or into its own subtree would orphan it.
            if target == id || item.children.contains(itemWithID: target) { return false }
        case .start, .end:
            break
        }
        var copy = self
        guard let removed = copy.removeItem(withID: id), copy.insert(removed, at: destination, now: now) else {
            return false
        }
        copy.repairSelections()
        self = copy
        return true
    }

    /// Adds a tab to the top of the archive and returns the new entry's id. Folders and tabs
    /// with no address have nothing to restore, so they return nil.
    @discardableResult
    public mutating func archive(_ item: SidebarItem, spaceID: UUID, at date: Date = Date()) -> UUID? {
        guard !item.isFolder, let url = item.url ?? item.homeURL else { return nil }
        let entry = ArchivedTab(title: item.displayTitle, url: url, spaceID: spaceID, archivedAt: date)
        archive.insert(entry, at: 0)
        if archive.count > BrowserState.archiveLimit {
            archive.removeLast(archive.count - BrowserState.archiveLimit)
        }
        return entry.id
    }

    /// Archives unpinned tabs nobody has looked at lately. Returns the ids that were archived so
    /// the caller can discard their live web views.
    @discardableResult
    public mutating func archiveStaleTabs(now: Date = Date(), protecting protected: Set<UUID> = []) -> [UUID] {
        guard let hours = settings.archiveAfterHours, hours > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-hours * 3600)
        var archivedIDs: [UUID] = []
        for index in spaces.indices {
            let space = spaces[index]
            let stale = space.tabs.filter { tab in
                // Only what can be archived is removed; anything else would vanish without a trace.
                !tab.isFolder && (tab.url ?? tab.homeURL) != nil
                    && tab.lastActiveAt < cutoff
                    && tab.id != space.selectedTabID
                    && tab.id != space.splitTabID
                    && !protected.contains(tab.id)
            }
            guard !stale.isEmpty else { continue }
            let staleIDs = Set(stale.map(\.id))
            // Oldest first, so the most recently used of them ends up at the top of the archive.
            for tab in stale.sorted(by: { $0.lastActiveAt < $1.lastActiveAt }) {
                archive(tab, spaceID: space.id, at: now)
            }
            spaces[index].tabs.removeAll { staleIDs.contains($0.id) }
            archivedIDs.append(contentsOf: staleIDs)
        }
        return archivedIDs
    }

    /// Removes a space, sending every tab it held to the archive. The last remaining space cannot
    /// be removed. Returns the tabs it held.
    @discardableResult
    public mutating func removeSpace(withID id: UUID, now: Date = Date()) -> [SidebarItem]? {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = spaces.remove(at: index)
        if currentSpaceID == id {
            currentSpaceID = spaces[min(index, spaces.count - 1)].id
        }
        let tabs = removed.pinned.allTabs + removed.tabs.allTabs
        // Reversed, so the space's first tab ends up at the top of the archive.
        for tab in tabs.reversed() {
            archive(tab, spaceID: removed.id, at: now)
        }
        return tabs
    }

    /// Removes a pinned tab, favorite or folder for good. Its tabs go to the archive, so nothing is
    /// lost outright. Returns what was removed.
    @discardableResult
    public mutating func deleteItem(withID id: UUID, now: Date = Date()) -> SidebarItem? {
        let spaceID = address(of: id)?.spaceID ?? currentSpaceID
        guard let removed = removeItem(withID: id) else { return nil }
        for tab in [removed].allTabs.reversed() {
            archive(tab, spaceID: spaceID, at: now)
        }
        repairSelections()
        return removed
    }

    /// Puts an archived tab back at the top of its space, or of the current space if its own is
    /// gone. Returns the restored tab's id.
    @discardableResult
    public mutating func restoreArchived(_ entryID: UUID, now: Date = Date()) -> UUID? {
        guard let index = archive.firstIndex(where: { $0.id == entryID }) else { return nil }
        let entry = archive.remove(at: index)
        let spaceID = space(withID: entry.spaceID) != nil ? entry.spaceID : currentSpaceID
        let item = SidebarItem.tab(url: entry.url, title: entry.title, now: now)
        insert(item, at: MoveDestination(spaceID: spaceID, section: .tabs, placement: .start), now: now)
        return item.id
    }

    // MARK: Selection

    /// Shows a tab, switching to its space. Favorites open in whichever space is current.
    @discardableResult
    public mutating func select(_ id: UUID, now: Date = Date()) -> Bool {
        guard let item = item(withID: id), !item.isFolder, let address = address(of: id) else { return false }
        let spaceID = address.spaceID ?? currentSpaceID
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return false }
        touchTabsOnScreen(now: now)
        if spaces[index].splitTabID == id {
            // Already in the other pane: swap the panes instead of showing it twice.
            spaces[index].splitTabID = spaces[index].selectedTabID
        }
        spaces[index].selectedTabID = id
        currentSpaceID = spaceID
        updateItem(withID: id) { $0.lastActiveAt = now }
        return true
    }

    /// Switches to another space.
    @discardableResult
    public mutating func showSpace(_ id: UUID, now: Date = Date()) -> Bool {
        guard id != currentSpaceID, space(withID: id) != nil else { return false }
        touchTabsOnScreen(now: now)
        currentSpaceID = id
        return true
    }

    /// Shows a tab from the current space beside the selected one, or closes the split with nil.
    @discardableResult
    public mutating func setSplit(_ id: UUID?, now: Date = Date()) -> Bool {
        let index = currentSpaceIndex
        if let id {
            guard let selected = spaces[index].selectedTabID, id != selected,
                  reachableTabIDs(inSpace: spaces[index].id).contains(id)
            else { return false }
        }
        touchTabsOnScreen(now: now)
        spaces[index].splitTabID = id
        if let id { updateItem(withID: id) { $0.lastActiveAt = now } }
        return true
    }

    /// What closing a tab did.
    public enum CloseOutcome: Equatable, Sendable {
        /// An unpinned tab was removed and archived as this entry.
        case archived(entryID: UUID)
        /// An unpinned tab with no address was removed; there was nothing to archive.
        case removed
        /// A pinned tab or favorite was unloaded and sent back to its home. It stays in the sidebar.
        case unloaded
    }

    /// Closes a tab the way the close button does. If it was on screen, the tab in the other
    /// split pane takes its place; otherwise the space is left with nothing selected.
    @discardableResult
    public mutating func close(_ id: UUID, now: Date = Date()) -> CloseOutcome? {
        guard let item = item(withID: id), !item.isFolder, let address = address(of: id) else { return nil }
        for index in spaces.indices {
            if spaces[index].splitTabID == id {
                spaces[index].splitTabID = nil
            }
            if spaces[index].selectedTabID == id {
                spaces[index].selectedTabID = spaces[index].splitTabID
                spaces[index].splitTabID = nil
            }
        }
        switch address.section {
        case .tabs:
            removeItem(withID: id)
            if let entryID = archive(item, spaceID: address.spaceID ?? currentSpaceID, at: now) {
                return .archived(entryID: entryID)
            }
            return .removed
        case .pinned, .favorites:
            updateItem(withID: id) { tab in
                tab.url = tab.homeURL ?? tab.url
                tab.lastActiveAt = now
            }
            return .unloaded
        }
    }

    /// Marks the tabs on screen in the current space as just used. Called as they leave the
    /// screen, so the archive clock runs from when a tab was last seen, not when it was opened.
    private mutating func touchTabsOnScreen(now: Date) {
        let space = currentSpace
        for id in [space.selectedTabID, space.splitTabID].compactMap({ $0 }) {
            updateItem(withID: id) { $0.lastActiveAt = now }
        }
    }

    /// Ids of every tab that can be shown in a space, including those in collapsed folders.
    public func reachableTabIDs(inSpace spaceID: UUID) -> Set<UUID> {
        guard let space = space(withID: spaceID) else { return [] }
        return Set((favorites(forSpace: spaceID).allTabs + space.pinned.allTabs + space.tabs.allTabs).map(\.id))
    }

    /// Ids of every item anywhere in the state, folders included.
    public var allItemIDs: Set<UUID> {
        func collect(_ items: [SidebarItem], into ids: inout Set<UUID>) {
            for item in items {
                ids.insert(item.id)
                collect(item.children, into: &ids)
            }
        }
        var ids = Set<UUID>()
        for space in spaces {
            collect(space.pinned, into: &ids)
            collect(space.tabs, into: &ids)
        }
        for profile in profiles {
            collect(profile.favorites, into: &ids)
        }
        return ids
    }

    // MARK: Consistency

    /// Clears selections that point at tabs which no longer exist in their space.
    public mutating func repairSelections() {
        for index in spaces.indices {
            let reachable = reachableTabIDs(inSpace: spaces[index].id)
            if let selected = spaces[index].selectedTabID, !reachable.contains(selected) {
                spaces[index].selectedTabID = nil
            }
            if let split = spaces[index].splitTabID, !reachable.contains(split) || split == spaces[index].selectedTabID {
                spaces[index].splitTabID = nil
            }
            // A split needs a primary tab beside it; promote the split tab if the primary is gone.
            if spaces[index].selectedTabID == nil, let split = spaces[index].splitTabID {
                spaces[index].selectedTabID = split
                spaces[index].splitTabID = nil
            }
        }
    }

    /// Makes a decoded state safe to run with, whatever happened to the file on disk.
    public mutating func repair() {
        if profiles.isEmpty {
            profiles = [Profile(name: "Personal")]
        }
        let profileIDs = Set(profiles.map(\.id))
        for index in spaces.indices where !profileIDs.contains(spaces[index].profileID) {
            spaces[index].profileID = profiles[0].id
        }
        if spaces.isEmpty {
            spaces = [Space(name: "Personal", icon: .symbol("house.fill"), profileID: profiles[0].id)]
        }
        if !spaces.contains(where: { $0.id == currentSpaceID }) {
            currentSpaceID = spaces[0].id
        }

        // Every item appears once, and folders live only in the pinned section. The code relies
        // on both, so a hand-edited or damaged file is brought back into line here.
        var seen = Set<UUID>()
        func clean(_ items: [SidebarItem], allowingFolders: Bool) -> [SidebarItem] {
            items.flatMap { item -> [SidebarItem] in
                guard seen.insert(item.id).inserted else { return [] }
                guard item.isFolder else { return [item] }
                guard allowingFolders else { return clean(item.children, allowingFolders: false) }
                var folder = item
                folder.children = clean(item.children, allowingFolders: true)
                return [folder]
            }
        }
        for index in spaces.indices {
            spaces[index].pinned = clean(spaces[index].pinned, allowingFolders: true)
            spaces[index].tabs = clean(spaces[index].tabs, allowingFolders: false).map { tab in
                var tab = tab
                tab.homeURL = nil
                return tab
            }
        }
        for index in profiles.indices {
            profiles[index].favorites = clean(profiles[index].favorites, allowingFolders: false).map { tab in
                var tab = tab
                tab.homeURL = tab.homeURL ?? tab.url
                return tab
            }
        }
        repairSelections()
    }
}

extension Placement {
    var folderID: UUID? {
        if case .inFolder(let id) = self { return id }
        return nil
    }
}

extension SidebarItem {
    /// Gives every tab in this subtree a home URL, which is what makes a tab "pinned".
    mutating func anchorTabs() {
        if isFolder {
            for index in children.indices {
                children[index].anchorTabs()
            }
        } else {
            homeURL = homeURL ?? url
        }
    }
}

// MARK: - Decoding

extension BrowserState {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Kept as read, so a caller can tell the file came from a newer version of Radian.
        schemaVersion = container.value(.schemaVersion, or: 1)
        profiles = container.lossyArray(.profiles)
        spaces = container.lossyArray(.spaces)
        currentSpaceID = container.value(.currentSpaceID, or: UUID())
        archive = container.lossyArray(.archive)
        settings = container.value(.settings, or: Settings())

        // Spaces exist but none could be read. Carrying on would replace them with a blank
        // state on the next save, so this counts as unreadable and the file is set aside instead.
        if spaces.isEmpty, container.elementCount(.spaces) > 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .spaces, in: container, debugDescription: "None of the saved spaces could be read."
            )
        }
    }
}
