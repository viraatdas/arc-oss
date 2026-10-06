import Foundation

/// What a line of text typed into the command bar means.
public enum InputResolution: Equatable, Sendable {
    case url(URL)
    case search(URL, query: String)

    public var url: URL {
        switch self {
        case .url(let url): url
        case .search(let url, _): url
        }
    }

    public var isSearch: Bool {
        if case .search = self { return true }
        return false
    }
}

public enum URLResolver {
    /// Schemes typed in full that are loaded as-is.
    private static let webSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob"]

    /// Schemes with no "//" that belong to other apps. Anything else shaped like "word:word" is
    /// more likely a search ("error: unexpected token") than an address.
    private static let externalSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio", "maps"]

    /// Real top-level domains that are far more often typed as a file name ("readme.md", "main.py").
    /// Endings with popular sites of their own (".ai", ".so", ".sh") are deliberately left out.
    private static let fileExtensions: Set<Substring> = ["md", "py", "rs", "ps", "zip", "mov"]

    /// Endings used on local networks. Devices there rarely serve https.
    private static let localSuffixes: Set<Substring> = ["local", "lan", "home", "internal", "localhost", "test"]

    /// Decides whether `raw` is an address or a search. Returns nil for blank input.
    public static func resolve(_ raw: String, engine: SearchEngine) -> InputResolution? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        func search() -> InputResolution { .search(engine.searchURL(for: input), query: input) }

        if let scheme = explicitScheme(in: input) {
            let isWeb = webSchemes.contains(scheme)
            let isDeepLink = input.dropFirst(scheme.count).hasPrefix("://")
            guard isWeb || externalSchemes.contains(scheme) || isDeepLink else { return search() }
            // A pasted path can contain spaces ("file:///Users/me/My Site/index.html").
            let encoded = input.replacingOccurrences(of: " ", with: "%20")
            guard !encoded.contains(where: \.isWhitespace), let url = URL(string: encoded) else { return search() }
            // Web pages load here; app links such as "mailto:" or "slack://" are handed to the
            // system by the caller.
            return .url(url)
        }

        guard !input.contains(where: \.isWhitespace), let authority = authority(of: input),
              let scheme = impliedScheme(forHost: authority.host, hasPort: authority.hasPort),
              let url = URL(string: "\(scheme)://\(input)"), url.host != nil
        else { return search() }
        return .url(url)
    }

    /// The scheme of inputs like "https://x" or "mailto:x". "localhost:3000" has no scheme: that is a port.
    private static func explicitScheme(in input: String) -> String? {
        guard let colon = input.firstIndex(of: ":") else { return nil }
        let candidate = input[input.startIndex..<colon]
        guard let first = candidate.first, first.isLetter,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        let rest = input[input.index(after: colon)...]
        let port = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if !port.isEmpty, port.allSatisfy(\.isNumber) { return nil }
        return candidate.lowercased()
    }

    /// The host before any path, and whether a numeric port follows it.
    private static func authority(of input: String) -> (host: Substring, hasPort: Bool)? {
        let authority = input.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.isEmpty, !authority.contains("@") else { return nil }
        if authority.hasPrefix("[") {
            return authority.contains("]") ? (authority, false) : nil
        }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let host = parts.first, !host.isEmpty else { return nil }
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) else { return nil }
            return (host, true)
        }
        return (host, false)
    }

    /// The scheme to assume for a bare host, or nil when the text does not look like a host at all.
    private static func impliedScheme(forHost host: Substring, hasPort: Bool) -> String? {
        let lowered = host.lowercased()
        if lowered.hasPrefix("[") { return "http" }

        let labels = lowered.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        let isHostLike = labels.allSatisfy { label in
            label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } && label.first != "-" && label.last != "-"
        }
        guard isHostLike, let tld = labels.last else { return nil }

        if labels.count == 4, labels.allSatisfy({ $0.allSatisfy(\.isNumber) && (Int($0) ?? 256) <= 255 }) {
            return "http"
        }
        if lowered == "localhost" || localSuffixes.contains(tld) { return "http" }
        // "devbox:3000": a bare machine name is only an address when it comes with a port.
        if labels.count == 1 { return hasPort ? "http" : nil }

        if tld.contains(where: { !$0.isASCII }) { return "https" }
        guard TopLevelDomains.all.contains(tld), !fileExtensions.contains(tld) || hasPort else { return nil }
        return "https"
    }
}
