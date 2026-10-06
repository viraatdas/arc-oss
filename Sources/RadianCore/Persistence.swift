import Foundation

public enum AppPaths {
    public static let appName = "Radian"

    /// Where state lives. `RADIAN_DATA_DIR` overrides the default, which keeps development and
    /// test runs away from real data.
    public static func dataDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["RADIAN_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appName, isDirectory: true)
    }
}

/// A Codable value stored as one JSON file.
public struct JSONFileStore<Value: Codable>: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Returns nil when the file does not exist yet.
    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: Data(contentsOf: url))
    }

    public enum LoadResult {
        case loaded(Value)
        /// There was no file yet.
        case missing
        /// The file could not be read and was moved to this address, where it is kept untouched.
        case setAside(URL)

        public var value: Value? {
            if case .loaded(let value) = self { return value }
            return nil
        }
    }

    /// Like `load`, but a file that cannot be decoded is moved aside instead of throwing, so one
    /// bad write never locks the user out and the old data stays recoverable.
    public func loadOrSetAside() -> LoadResult {
        do {
            return try load().map(LoadResult.loaded) ?? .missing
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let destination = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            let fileManager = FileManager.default
            if (try? fileManager.moveItem(at: url, to: destination)) != nil
                || (try? fileManager.copyItem(at: url, to: destination)) != nil {
                return .setAside(destination)
            }
            // Neither worked, so the folder cannot be written to and saving will fail the same way:
            // the file stays where it is, unharmed.
            return .setAside(url)
        }
    }

    /// Copies the file next to itself before something that might overwrite it. Returns the copy.
    @discardableResult
    public func backUp(suffix: String) -> URL? {
        let destination = url.deletingPathExtension().appendingPathExtension("\(suffix).json")
        try? FileManager.default.removeItem(at: destination)
        return (try? FileManager.default.copyItem(at: url, to: destination)) != nil ? destination : nil
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
