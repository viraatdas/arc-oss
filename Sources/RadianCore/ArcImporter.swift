import CryptoKit
import Foundation

public enum ArcImportError: Error, LocalizedError, Equatable {
    case unreadable(path: String, reason: String)
    case notJSON
    case unrecognizedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            "Could not read \(path): \(reason)"
        case .notJSON:
            "The file is not valid JSON."
        case .unrecognizedFormat(let detail):
            "This does not look like an Arc sidebar file (\(detail))."
        }
    }
}

/// What an Arc sidebar file contained, converted to Radian's model.
public struct ArcImportResult: Equatable, Sendable {
    public struct Stats: Equatable, Sendable {
        public var spaces = 0
        public var pinnedTabs = 0
        public var folders = 0
        public var unpinnedTabs = 0
        public var favorites = 0
        /// Entries with no Radian equivalent, such as Arc's onboarding card or internal pages.
        public var skipped = 0
    }

    /// The first profile is always Arc's default profile, identified by `ArcImporter.defaultProfileID`.
    public var profiles: [Profile]
    public var spaces: [Space]
    public var stats: Stats
}

/// Reads the sidebar file Arc keeps in `~/Library/Application Support/Arc/StorableSidebar.json`.
///
/// The format is undocumented; `docs/arc-sidebar-format.md` records what is known about it.
/// Everything here is defensive: unknown shapes are skipped rather than treated as errors.
public enum ArcImporter {
    /// Stands in for Arc's default profile. `BrowserState.merge` maps it onto the user's own default.
    public static let defaultProfileID = stableUUID(for: "arc-profile:default")

    public static var defaultSidebarURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
    }

    public static func importSidebar(at url: URL) throws -> ArcImportResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ArcImportError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        return try importSidebar(data: data)
    }

    public static func importSidebar(data: Data, now: Date = Date()) throws -> ArcImportResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ArcImportError.notJSON
        }
        guard let sidebar = root["sidebar"] as? [String: Any], let containers = sidebar["containers"] as? [Any] else {
            throw ArcImportError.unrecognizedFormat("no sidebar.containers")
        }
        guard let container = containers.compactMap({ $0 as? [String: Any] })
            .first(where: { $0["items"] != nil && $0["spaces"] != nil })
        else {
            throw ArcImportError.unrecognizedFormat("no container holding items and spaces")
        }

        var converter = Converter(items: objects(in: container["items"]), now: now)
        var stats = ArcImportResult.Stats()

        // Profiles, in first-seen order, keyed by Arc's profile directory name.
        var profileOrder = [Converter.defaultProfileKey]
        var favoritesByProfile: [String: [SidebarItem]] = [:]
        func noteProfile(_ key: String) {
            if !profileOrder.contains(key) { profileOrder.append(key) }
        }

        // Favorites ("top apps") hang off one container per profile.
        for (id, item) in converter.items.sorted(by: { $0.key < $1.key }) {
            guard let topApps = containerType(of: item)?["topApps"] else { continue }
            let key = profileKey(from: topApps)
            noteProfile(key)
            let favorites = converter.convert(childrenOf: id, pinned: true, flatten: true)
            favoritesByProfile[key, default: []].append(contentsOf: favorites)
        }

        var spaces: [Space] = []
        for raw in objects(in: container["spaces"]) {
            guard let arcID = raw["id"] as? String else { continue }
            let key = profileKey(from: raw["profile"])
            noteProfile(key)

            // Older files have only `containerIDs`; newer ones add `newContainerIDs`, whose keys
            // are enum values such as {"unpinned": {...}} rather than plain strings.
            let containerLists = [raw["containerIDs"], raw["newContainerIDs"]].compactMap { $0 as? [Any] }
            let pinnedID = containerLists.lazy.compactMap { value(after: "pinned", in: $0) }.first
            let unpinnedID = containerLists.lazy.compactMap { value(after: "unpinned", in: $0) }.first
            let pinned = pinnedID.map { converter.convert(childrenOf: $0, pinned: true, flatten: false) } ?? []
            let tabs = unpinnedID.map { converter.convert(childrenOf: $0, pinned: false, flatten: true) } ?? []

            let title = (raw["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let custom = raw["customInfo"] as? [String: Any]
            spaces.append(
                Space(
                    id: stableUUID(for: arcID),
                    name: title ?? "Space \(spaces.count + 1)",
                    icon: icon(from: custom?["iconType"]) ?? .symbol("circle.fill"),
                    theme: theme(from: custom?["windowTheme"])
                        ?? SpaceTheme.presets[spaces.count % SpaceTheme.presets.count],
                    profileID: profileID(forKey: key),
                    pinned: pinned,
                    tabs: tabs
                )
            )
            stats.pinnedTabs += pinned.allTabs.count
            stats.unpinnedTabs += tabs.count
        }
        guard !spaces.isEmpty else {
            throw ArcImportError.unrecognizedFormat("no spaces found")
        }

        let profiles = profileOrder.enumerated().map { index, key in
            Profile(
                id: profileID(forKey: key),
                name: key == Converter.defaultProfileKey ? "Default" : "Arc \(key)",
                favorites: favoritesByProfile[key] ?? []
            )
        }
        stats.spaces = spaces.count
        stats.folders = converter.folderCount
        stats.favorites = profiles.reduce(0) { $0 + $1.favorites.count }
        stats.skipped = converter.skippedCount
        return ArcImportResult(profiles: profiles, spaces: spaces, stats: stats)
    }

    // MARK: - Conversion

    private struct Converter {
        static let defaultProfileKey = "default"

        let items: [String: [String: Any]]
        let now: Date
        var folderCount = 0
        var skippedCount = 0
        /// Guards against a corrupt file whose items form a cycle.
        private var visited: Set<String> = []

        init(items: [[String: Any]], now: Date) {
            var byID: [String: [String: Any]] = [:]
            for item in items {
                if let id = item["id"] as? String { byID[id] = item }
            }
            self.items = byID
            self.now = now
        }

        mutating func convert(childrenOf id: String, pinned: Bool, flatten: Bool) -> [SidebarItem] {
            guard let children = items[id]?["childrenIds"] as? [String] else { return [] }
            return children.flatMap { convert(itemID: $0, pinned: pinned, flatten: flatten) }
        }

        /// One Arc item becomes zero or more sidebar items: split views dissolve into their tabs,
        /// and folders dissolve too when `flatten` is set (the destination cannot hold folders).
        private mutating func convert(itemID: String, pinned: Bool, flatten: Bool) -> [SidebarItem] {
            guard visited.insert(itemID).inserted, let node = items[itemID],
                  let data = node["data"] as? [String: Any]
            else { return [] }

            let customTitle = (node["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let created = ArcImporter.date(node["createdAt"]) ?? now

            if let tab = data["tab"] as? [String: Any] {
                guard let string = tab["savedURL"] as? String, let url = URL(string: string),
                      let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme)
                else {
                    skippedCount += 1
                    return []
                }
                return [
                    SidebarItem(
                        id: stableUUID(for: itemID),
                        kind: .tab,
                        title: tab["savedTitle"] as? String ?? "",
                        customTitle: customTitle,
                        url: url,
                        homeURL: pinned ? url : nil,
                        createdAt: created,
                        // Imported tabs start a fresh archive clock rather than vanishing on first launch.
                        lastActiveAt: now
                    ),
                ]
            }
            if data["list"] != nil {
                let children = convert(childrenOf: itemID, pinned: pinned, flatten: flatten)
                if flatten { return children }
                folderCount += 1
                return [
                    SidebarItem.folder(
                        name: customTitle ?? "Folder",
                        children: children,
                        id: stableUUID(for: itemID),
                        now: created
                    ),
                ]
            }
            if data["splitView"] != nil {
                return convert(childrenOf: itemID, pinned: pinned, flatten: flatten)
            }
            skippedCount += 1
            return []
        }
    }

    // MARK: - Parsing helpers

    /// Arc writes keyed collections as flat arrays that alternate key, value, key, value.
    /// Only the values matter here, since each carries its own id.
    private static func objects(in value: Any?) -> [[String: Any]] {
        (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    /// In a flat key, value list, the value whose key is `tag`, written either as the string
    /// itself or as an enum object with `tag` as its only key.
    private static func value(after tag: String, in list: [Any]) -> String? {
        let index = list.firstIndex { key in
            (key as? String) == tag || (key as? [String: Any])?.keys.contains(tag) == true
        }
        guard let index, index + 1 < list.count else { return nil }
        return list[index + 1] as? String
    }

    private static func containerType(of item: [String: Any]) -> [String: Any]? {
        let data = item["data"] as? [String: Any]
        let itemContainer = data?["itemContainer"] as? [String: Any]
        return itemContainer?["containerType"] as? [String: Any]
    }

    /// A profile is written as `{"default": true}` or `{"custom": {"_0": {"directoryBasename": ...}}}`,
    /// sometimes wrapped in another `{"_0": ...}` layer.
    private static func profileKey(from value: Any?) -> String {
        firstString(forKey: "directoryBasename", in: value) ?? Converter.defaultProfileKey
    }

    private static func profileID(forKey key: String) -> UUID {
        key == Converter.defaultProfileKey ? defaultProfileID : stableUUID(for: "arc-profile:\(key)")
    }

    private static func date(_ value: Any?) -> Date? {
        // Seconds since the Cocoa reference date (2001-01-01), not the Unix epoch.
        (value as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
    }

    private static func icon(from value: Any?) -> SpaceIcon? {
        guard let iconType = value as? [String: Any] else { return nil }
        if let emoji = iconType["emoji_v2"] as? String, !emoji.isEmpty { return .emoji(emoji) }
        if let codePoint = (iconType["emoji"] as? NSNumber)?.uint32Value, let scalar = Unicode.Scalar(codePoint) {
            return .emoji(String(Character(scalar)))
        }
        if let name = iconType["icon"] as? String { return .symbol(symbolNames[name] ?? name) }
        return nil
    }

    /// Arc names its built-in space icons with its own vocabulary. These are the closest SF Symbols
    /// for the names seen so far; anything else passes through and renders as a neutral glyph.
    private static let symbolNames: [String: String] = [
        "flash": "bolt.fill",
        "planet": "globe.americas.fill",
        "star": "star.fill",
        "heart": "heart.fill",
        "home": "house.fill",
        "moon": "moon.fill",
        "sunny": "sun.max.fill",
        "leaf": "leaf.fill",
        "flame": "flame.fill",
        "briefcase": "briefcase.fill",
        "book": "book.fill",
        "code": "chevron.left.forwardslash.chevron.right",
        "person": "person.fill",
        "people": "person.2.fill",
        "cloud": "cloud.fill",
        "cart": "cart.fill",
        "bookmark": "bookmark.fill",
        "airplane": "airplane",
        "school": "graduationcap.fill",
        "musicalNotes": "music.note",
        "gameController": "gamecontroller.fill",
    ]

    private static func theme(from value: Any?) -> SpaceTheme? {
        guard let windowTheme = value as? [String: Any] else { return nil }
        let background = windowTheme["background"]
        var colors: [RGBAColor] = []
        if let stops = firstValue(forKey: "baseColors", in: background, where: { $0 is [Any] }) as? [Any] {
            colors = stops.compactMap { color(from: $0) }
        }
        if colors.isEmpty, let single = firstValue(forKey: "color", in: background, where: { color(from: $0) != nil }) {
            colors = [color(from: single)].compactMap { $0 }
        }
        if colors.isEmpty, let palette = windowTheme["primaryColorPalette"] as? [String: Any],
           let midTone = color(from: palette["midTone"]) {
            colors = [midTone]
        }
        guard !colors.isEmpty else { return nil }
        let intensity = (firstValue(forKey: "intensityFactor", in: background, where: { $0 is NSNumber }) as? NSNumber)?
            .doubleValue
        return SpaceTheme(colors: colors, intensity: min(max(intensity ?? 0.6, 0.35), 1))
    }

    private static func color(from value: Any?) -> RGBAColor? {
        guard let dictionary = value as? [String: Any],
              let red = (dictionary["red"] as? NSNumber)?.doubleValue,
              let green = (dictionary["green"] as? NSNumber)?.doubleValue,
              let blue = (dictionary["blue"] as? NSNumber)?.doubleValue
        else { return nil }
        // Arc stores extended sRGB, whose components can fall outside 0...1.
        func clamp(_ component: Double) -> Double { min(max(component, 0), 1) }
        return RGBAColor(red: clamp(red), green: clamp(green), blue: clamp(blue))
    }

    /// Depth-first search for the first value under `key` that satisfies `predicate`.
    private static func firstValue(forKey key: String, in value: Any?, where predicate: (Any) -> Bool) -> Any? {
        if let dictionary = value as? [String: Any] {
            if let direct = dictionary[key], predicate(direct) { return direct }
            for child in dictionary.keys.sorted() {
                if let found = firstValue(forKey: key, in: dictionary[child], where: predicate) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = firstValue(forKey: key, in: child, where: predicate) { return found }
            }
        }
        return nil
    }

    private static func firstString(forKey key: String, in value: Any?) -> String? {
        firstValue(forKey: key, in: value, where: { $0 is String }) as? String
    }
}

/// Maps an Arc identifier to a UUID, the same one every time, so importing twice is idempotent.
/// Arc's ids are mostly UUIDs already, but a few are well-known strings.
func stableUUID(for string: String) -> UUID {
    if let uuid = UUID(uuidString: string) { return uuid }
    let digest = Array(SHA256.hash(data: Data(string.utf8)))
    return UUID(uuid: (
        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
        digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
    ))
}

// MARK: - Merging into existing state

public struct ArcMergeSummary: Equatable, Sendable {
    public var addedSpaceIDs: [UUID] = []
    /// Spaces that were already imported on an earlier run and left alone.
    public var skippedSpaces = 0
    public var addedFavorites = 0
}

extension BrowserState {
    /// Adds imported spaces and favorites. Anything already here, under any space or profile, is
    /// left untouched, so running the import again never duplicates or clobbers what is there.
    /// Spaces and favorites deleted since the last import do come back.
    @discardableResult
    public mutating func merge(_ imported: ArcImportResult) -> ArcMergeSummary {
        var summary = ArcMergeSummary()
        guard let localDefault = profiles.first?.id else { return summary }

        // An item the user has since moved elsewhere keeps its id, so ids are checked across the
        // whole state, not just where the item started out.
        var knownIDs = allItemIDs
        func unseen(_ items: [SidebarItem]) -> [SidebarItem] {
            items.compactMap { item in
                guard knownIDs.insert(item.id).inserted else { return nil }
                var item = item
                item.children = unseen(item.children)
                return item
            }
        }

        func localProfileID(for importedID: UUID) -> UUID {
            importedID == ArcImporter.defaultProfileID ? localDefault : importedID
        }

        let neededProfiles = Set(imported.spaces.map(\.profileID))
        for profile in imported.profiles {
            let localID = localProfileID(for: profile.id)
            let fresh = unseen(profile.favorites)
            if let index = profiles.firstIndex(where: { $0.id == localID }) {
                profiles[index].favorites.append(contentsOf: fresh)
                summary.addedFavorites += fresh.count
            } else if neededProfiles.contains(profile.id) || !fresh.isEmpty {
                var profile = profile
                profile.favorites = fresh
                profiles.append(profile)
                summary.addedFavorites += fresh.count
            }
        }

        let existingSpaces = Set(spaces.map(\.id))
        for var space in imported.spaces {
            guard !existingSpaces.contains(space.id) else {
                summary.skippedSpaces += 1
                continue
            }
            space.profileID = localProfileID(for: space.profileID)
            space.pinned = unseen(space.pinned)
            space.tabs = unseen(space.tabs)
            spaces.append(space)
            summary.addedSpaceIDs.append(space.id)
        }
        repair()
        return summary
    }
}
