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

    /// Endings that look like a top-level domain but are far more often a file name ("main.swift").
    private static let fileExtensions: Set<String> = [
        "js", "ts", "jsx", "tsx", "json", "txt", "png", "jpg", "jpeg", "gif", "svg", "css", "html", "htm",
        "php", "swift", "cpp", "java", "kt", "rb", "exe", "pdf", "yml", "yaml", "toml", "lock", "log",
        "conf", "cfg", "ini", "xml", "csv",
    ]

    /// Decides whether `raw` is an address or a search. Returns nil for blank input.
    public static func resolve(_ raw: String, engine: SearchEngine) -> InputResolution? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        func search() -> InputResolution { .search(engine.searchURL(for: input), query: input) }

        guard !input.contains(where: \.isWhitespace) else { return search() }

        if let scheme = explicitScheme(in: input) {
            // Web pages load here; app links such as "mailto:" or "slack://" are handed to the
            // system by the caller.
            let isDeepLink = input.dropFirst(scheme.count).hasPrefix("://")
            if webSchemes.contains(scheme) || externalSchemes.contains(scheme) || isDeepLink,
               let url = URL(string: input) {
                return .url(url)
            }
            return search()
        }

        guard let host = hostPortion(of: input), let scheme = impliedScheme(forHost: host) else { return search() }
        guard let url = URL(string: "\(scheme)://\(input)"), url.host != nil else { return search() }
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

    /// The part before the path, without any port.
    private static func hostPortion(of input: String) -> String? {
        let authority = input.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.isEmpty, !authority.contains("@") else { return nil }
        if authority.hasPrefix("[") {
            return authority.contains("]") ? String(authority) : nil
        }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let host = parts.first, !host.isEmpty else { return nil }
        if parts.count == 2, !(parts[1].allSatisfy(\.isNumber) && !parts[1].isEmpty) { return nil }
        return String(host)
    }

    /// The scheme to assume for a bare host, or nil when the text does not look like a host at all.
    private static func impliedScheme(forHost host: String) -> String? {
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered.hasSuffix(".localhost") || lowered.hasPrefix("[") { return "http" }

        let labels = lowered.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }

        if labels.count == 4, labels.allSatisfy({ $0.allSatisfy(\.isNumber) && (Int($0) ?? 256) <= 255 }) {
            return "http"
        }
        guard labels.allSatisfy({ label in label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
              let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter),
              !fileExtensions.contains(String(tld))
        else { return nil }
        return "https"
    }
}
