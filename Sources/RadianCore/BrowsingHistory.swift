import Foundation

public struct HistoryEntry: Codable, Equatable, Sendable {
    public var url: URL
    public var title: String
    public var visitCount: Int
    public var lastVisited: Date

    public init(url: URL, title: String, visitCount: Int, lastVisited: Date) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisited = lastVisited
    }
}

/// Pages the user has visited, kept only to power command bar suggestions.
public struct BrowsingHistory: Codable, Equatable, Sendable {
    public private(set) var entries: [String: HistoryEntry]
    public var limit: Int

    public init(limit: Int = 5000) {
        self.entries = [:]
        self.limit = limit
    }

    public mutating func record(url: URL, title: String, at date: Date = Date()) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let key = url.absoluteString
        if var existing = entries[key] {
            existing.visitCount += 1
            existing.lastVisited = date
            if !title.isEmpty { existing.title = title }
            entries[key] = existing
        } else {
            entries[key] = HistoryEntry(url: url, title: title, visitCount: 1, lastVisited: date)
            trim()
        }
    }

    public mutating func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty else { return }
        entries[url.absoluteString]?.title = title
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    /// The best matches for a query, ranked by text match and then by how often and how recently
    /// the page was visited.
    public func search(_ query: String, limit: Int = 6, now: Date = Date()) -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var scored: [(entry: HistoryEntry, score: Double)] = []
        for entry in entries.values {
            let titleScore = FuzzyMatch.score(query: trimmed, candidate: entry.title)
            let urlScore = FuzzyMatch.score(query: trimmed, candidate: BrowsingHistory.displayURL(entry.url))
            guard let best = [titleScore, urlScore].compactMap({ $0 }).max() else { continue }
            scored.append((entry, Double(best) + frecency(entry, now: now)))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry.url.absoluteString < $1.entry.url.absoluteString }
            .prefix(limit)
            .map(\.entry)
    }

    /// The most-visited site whose host begins with `prefix`, for "type gi, get github.com".
    /// Visits are added up across each site's pages, and the site's front page is what is offered.
    public func bestHostMatch(forPrefix prefix: String) -> HistoryEntry? {
        let needle = prefix.lowercased()
        guard needle.count >= 2 else { return nil }

        var sites: [String: [HistoryEntry]] = [:]
        for entry in entries.values {
            let host = BrowsingHistory.bareHost(entry.url)
            if host.hasPrefix(needle) { sites[host, default: []].append(entry) }
        }
        func weight(_ pages: [HistoryEntry]) -> (Int, Date) {
            (pages.reduce(0) { $0 + $1.visitCount }, pages.map(\.lastVisited).max() ?? .distantPast)
        }
        guard let (_, pages) = sites.max(by: { weight($0.value) < weight($1.value) }),
              let busiest = pages.max(by: { $0.visitCount < $1.visitCount })
        else { return nil }

        let (visits, lastVisited) = weight(pages)
        if let front = pages.first(where: { ["", "/"].contains($0.url.path) && $0.url.query == nil }) {
            return HistoryEntry(url: front.url, title: front.title, visitCount: visits, lastVisited: lastVisited)
        }
        var components = URLComponents()
        components.scheme = busiest.url.scheme
        components.host = busiest.url.host
        components.port = busiest.url.port
        components.path = "/"
        guard let url = components.url else { return busiest }
        return HistoryEntry(url: url, title: url.host ?? "", visitCount: visits, lastVisited: lastVisited)
    }

    /// A URL the way people type it: no scheme, no "www.", no trailing slash.
    public static func displayURL(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    public static func bareHost(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func frecency(_ entry: HistoryEntry, now: Date) -> Double {
        let days = max(now.timeIntervalSince(entry.lastVisited), 0) / 86_400
        return log2(Double(entry.visitCount) + 1) * 20 + 60 / (1 + days)
    }

    /// Drops the least recently visited tenth once the store is over its limit.
    private mutating func trim() {
        guard entries.count > limit else { return }
        let excess = entries.count - limit + limit / 10
        let oldest = entries.values.sorted { $0.lastVisited < $1.lastVisited }.prefix(excess)
        for entry in oldest {
            entries[entry.url.absoluteString] = nil
        }
    }
}
