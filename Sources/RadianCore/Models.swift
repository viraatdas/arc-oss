import Foundation

/// An sRGB color, stored as plain components so themes round-trip through JSON.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    public var luminance: Double {
        func linear(_ component: Double) -> Double {
            let c = min(max(component, 0), 1)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// The gradient a space paints behind the sidebar.
public struct SpaceTheme: Codable, Hashable, Sendable {
    /// One to three gradient stops.
    public var colors: [RGBAColor]
    /// How strongly the gradient shows over the window material, 0...1.
    public var intensity: Double

    public init(colors: [RGBAColor], intensity: Double = 0.6) {
        self.colors = colors.isEmpty ? [SpaceTheme.fallbackColor] : Array(colors.prefix(3))
        self.intensity = min(max(intensity, 0), 1)
    }

    static let fallbackColor = RGBAColor(hex: 0x6E7BF2)

    /// Always at least two stops, so it can be handed straight to a gradient.
    public var gradientStops: [RGBAColor] {
        let stops = colors.isEmpty ? [SpaceTheme.fallbackColor] : colors
        return stops.count == 1 ? [stops[0], stops[0]] : stops
    }

    public var averageLuminance: Double {
        let stops = gradientStops
        return stops.map(\.luminance).reduce(0, +) / Double(stops.count)
    }

    public static let presets: [SpaceTheme] = [
        SpaceTheme(colors: [RGBAColor(hex: 0x6E7BF2), RGBAColor(hex: 0xB57BEE)]),
        SpaceTheme(colors: [RGBAColor(hex: 0xFF8A6B), RGBAColor(hex: 0xFF5E8A)]),
        SpaceTheme(colors: [RGBAColor(hex: 0x5FB48C), RGBAColor(hex: 0xA8D672)]),
        SpaceTheme(colors: [RGBAColor(hex: 0x4FA8F5), RGBAColor(hex: 0x7FE0E8)]),
        SpaceTheme(colors: [RGBAColor(hex: 0xE9C58A), RGBAColor(hex: 0xF2A07B)]),
        SpaceTheme(colors: [RGBAColor(hex: 0xF29CB7), RGBAColor(hex: 0xC59BF0)]),
        SpaceTheme(colors: [RGBAColor(hex: 0x8A93A6), RGBAColor(hex: 0x4B5568)]),
        SpaceTheme(colors: [RGBAColor(hex: 0x1F2440), RGBAColor(hex: 0x4A2F6E)], intensity: 0.85),
    ]
}

public enum SpaceIcon: Codable, Hashable, Sendable {
    case emoji(String)
    /// An SF Symbol name. Unknown names fall back to a neutral glyph at render time.
    case symbol(String)
}

/// A node in the sidebar: either a tab or a folder of nodes.
public struct SidebarItem: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case tab
        case folder
    }

    public var id: UUID
    public var kind: Kind
    /// The page title for a tab, or the name of a folder.
    public var title: String
    /// A user-chosen name that overrides the page title.
    public var customTitle: String?
    /// Where the tab currently is.
    public var url: URL?
    /// Pinned tabs and favorites remember where they live and return there when closed.
    public var homeURL: URL?
    public var children: [SidebarItem]
    public var isExpanded: Bool
    public var createdAt: Date
    public var lastActiveAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        customTitle: String? = nil,
        url: URL? = nil,
        homeURL: URL? = nil,
        children: [SidebarItem] = [],
        isExpanded: Bool = false,
        createdAt: Date = Date(),
        lastActiveAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.customTitle = customTitle
        self.url = url
        self.homeURL = homeURL
        self.children = children
        self.isExpanded = isExpanded
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }

    public static func tab(url: URL, title: String? = nil, id: UUID = UUID(), now: Date = Date()) -> SidebarItem {
        SidebarItem(id: id, kind: .tab, title: title ?? "", url: url, createdAt: now, lastActiveAt: now)
    }

    public static func folder(
        name: String,
        children: [SidebarItem] = [],
        id: UUID = UUID(),
        now: Date = Date()
    ) -> SidebarItem {
        SidebarItem(id: id, kind: .folder, title: name, children: children, createdAt: now, lastActiveAt: now)
    }

    public var isFolder: Bool { kind == .folder }

    public var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if !title.isEmpty { return title }
        if isFolder { return "Untitled Folder" }
        return (url ?? homeURL)?.host ?? "New Tab"
    }
}

/// A browsing identity. Spaces that share a profile share cookies, logins and favorites.
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var favorites: [SidebarItem]

    public init(id: UUID = UUID(), name: String, favorites: [SidebarItem] = []) {
        self.id = id
        self.name = name
        self.favorites = favorites
    }
}

public struct Space: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var icon: SpaceIcon
    public var theme: SpaceTheme
    public var profileID: UUID
    /// Pinned tabs and folders. These persist until removed.
    public var pinned: [SidebarItem]
    /// Unpinned tabs, newest first. These are archived once they go stale.
    public var tabs: [SidebarItem]
    public var selectedTabID: UUID?
    /// The tab shown beside the selected one when split view is on.
    public var splitTabID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        icon: SpaceIcon = .symbol("circle.fill"),
        theme: SpaceTheme = SpaceTheme.presets[0],
        profileID: UUID,
        pinned: [SidebarItem] = [],
        tabs: [SidebarItem] = [],
        selectedTabID: UUID? = nil,
        splitTabID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.theme = theme
        self.profileID = profileID
        self.pinned = pinned
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.splitTabID = splitTabID
    }
}

public struct ArchivedTab: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var spaceID: UUID
    public var archivedAt: Date

    public init(id: UUID = UUID(), title: String, url: URL, spaceID: UUID, archivedAt: Date) {
        self.id = id
        self.title = title
        self.url = url
        self.spaceID = spaceID
        self.archivedAt = archivedAt
    }
}

public enum SearchEngine: String, Codable, CaseIterable, Sendable {
    case google
    case duckDuckGo
    case bing
    case kagi
    case brave

    public var displayName: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .kagi: "Kagi"
        case .brave: "Brave Search"
        }
    }

    private var endpoint: String {
        switch self {
        case .google: "https://www.google.com/search"
        case .duckDuckGo: "https://duckduckgo.com/"
        case .bing: "https://www.bing.com/search"
        case .kagi: "https://kagi.com/search"
        case .brave: "https://search.brave.com/search"
        }
    }

    public func searchURL(for query: String) -> URL {
        var components = URLComponents(string: endpoint)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        // URLComponents leaves "+" alone, which servers decode as a space ("c++" would become "c  ").
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var searchEngine: SearchEngine
    /// Unpinned tabs untouched for this long are archived. `nil` disables archiving.
    public var archiveAfterHours: Double?
    public var sidebarWidth: Double

    public init(searchEngine: SearchEngine = .google, archiveAfterHours: Double? = 12, sidebarWidth: Double = 260) {
        self.searchEngine = searchEngine
        self.archiveAfterHours = archiveAfterHours
        self.sidebarWidth = sidebarWidth
    }

    enum CodingKeys: String, CodingKey {
        case searchEngine, archiveAfterHours, sidebarWidth
    }

    // Decoded field by field so that settings added later do not invalidate older files.
    public init(from decoder: Decoder) throws {
        let defaults = Settings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        searchEngine = (try? container.decodeIfPresent(SearchEngine.self, forKey: .searchEngine)) ?? defaults.searchEngine
        if container.contains(.archiveAfterHours) {
            archiveAfterHours = try? container.decodeIfPresent(Double.self, forKey: .archiveAfterHours)
        } else {
            archiveAfterHours = defaults.archiveAfterHours
        }
        sidebarWidth = (try? container.decodeIfPresent(Double.self, forKey: .sidebarWidth)) ?? defaults.sidebarWidth
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(searchEngine, forKey: .searchEngine)
        // Written even when nil: an absent key means "use the default", null means "never archive".
        try container.encode(archiveAfterHours, forKey: .archiveAfterHours)
        try container.encode(sidebarWidth, forKey: .sidebarWidth)
    }
}
