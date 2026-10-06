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
    public static let archiveLimit = 500

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
    public mutating func insert(_ item: SidebarItem, at destination: MoveDestination) -> Bool {
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
            return spaces[spaceIndex].tabs.place(item, destination.placement)
        }
    }

    /// Moves an item anywhere in the sidebar. All-or-nothing: on failure the state is unchanged.
    @discardableResult
    public mutating func move(_ id: UUID, to destination: MoveDestination) -> Bool {
        guard let item = item(withID: id) else { return false }
        switch destination.placement {
        case .before(let target), .inFolder(let target):
            // Dropping an item onto itself or into its own subtree would orphan it.
            if target == id || item.children.contains(itemWithID: target) { return false }
        case .start, .end:
            break
        }
        var copy = self
        guard let removed = copy.removeItem(withID: id), copy.insert(removed, at: destination) else { return false }
        copy.repairSelections()
        self = copy
        return true
    }

    public mutating func archive(_ item: SidebarItem, spaceID: UUID, at date: Date = Date()) {
        guard !item.isFolder, let url = item.url ?? item.homeURL else { return }
        archive.insert(
            ArchivedTab(title: item.displayTitle, url: url, spaceID: spaceID, archivedAt: date),
            at: 0
        )
        if archive.count > BrowserState.archiveLimit {
            archive.removeLast(archive.count - BrowserState.archiveLimit)
        }
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
                tab.lastActiveAt < cutoff
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

    /// Removes a space. The last remaining space cannot be removed. Returns the tabs it held.
    @discardableResult
    public mutating func removeSpace(withID id: UUID) -> [SidebarItem]? {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = spaces.remove(at: index)
        if currentSpaceID == id {
            currentSpaceID = spaces[min(index, spaces.count - 1)].id
        }
        return removed.pinned.allTabs + removed.tabs.allTabs
    }

    /// Clears selections that point at tabs which no longer exist in their space.
    public mutating func repairSelections() {
        for index in spaces.indices {
            let spaceID = spaces[index].id
            let reachable = Set(
                (favorites(forSpace: spaceID).allTabs + spaces[index].pinned.allTabs + spaces[index].tabs.allTabs)
                    .map(\.id)
            )
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
