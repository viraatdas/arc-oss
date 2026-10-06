import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Site icons, one per host, cached in memory and on disk.
///
/// Icons come from addresses a page chooses and are fetched outside WebKit's sandbox, so the
/// fetch is limited: web addresses only, a few hundred kilobytes at most, and decoding happens
/// off the main thread straight into a small thumbnail.
@MainActor
@Observable
final class FaviconStore {
    private nonisolated static let byteLimit = 512 * 1024
    private nonisolated static let side = 64

    private var images: [String: NSImage] = [:]

    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let session: URLSession

    init(directory: URL) {
        self.directory = directory
        // Icon requests carry no cookies and leave nothing behind but the icon.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: configuration)
    }

    /// The icon for a page, or nil while it is unknown. Asking starts a lookup the first time, and
    /// views that asked redraw when the icon arrives.
    func image(for url: URL?) -> NSImage? {
        guard let url, let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if let image = images[host] { return image }
        if requested.insert(host).inserted {
            let scheme = url.scheme?.lowercased() ?? "https"
            Task { await loadDefaultIcon(host: host, scheme: scheme) }
        }
        return nil
    }

    /// Records the icon a page declares for itself, which beats the /favicon.ico guess.
    func setIcon(_ iconURL: URL, forPage pageURL: URL) {
        guard let host = pageURL.host?.lowercased(), !host.isEmpty else { return }
        requested.insert(host)
        Task {
            guard let icon = await fetch(iconURL) else { return }
            store(icon, forHost: host)
        }
    }

    private func loadDefaultIcon(host: String, scheme: String) async {
        let file = fileURL(forHost: host)
        if let cached = await Task.detached(operation: { FaviconStore.thumbnail(fromFile: file) }).value {
            images[host] = NSImage(cgImage: cached, size: NSSize(width: 32, height: 32))
            return
        }
        guard let url = URL(string: "\(scheme)://\(host)/favicon.ico"), let icon = await fetch(url) else { return }
        // A page-declared icon may have landed while this request was in flight; it wins.
        if images[host] == nil {
            store(icon, forHost: host)
        }
    }

    private func fetch(_ url: URL) async -> CGImage? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let session = self.session
        return await Task.detached {
            guard let data = await FaviconStore.download(url, with: session) else { return nil }
            return FaviconStore.thumbnail(from: data)
        }.value
    }

    private func store(_ icon: CGImage, forHost host: String) {
        images[host] = NSImage(cgImage: icon, size: NSSize(width: 32, height: 32))
        let file = fileURL(forHost: host)
        let directory = self.directory
        Task.detached {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FaviconStore.writePNG(icon, to: file)
        }
    }

    private func fileURL(forHost host: String) -> URL {
        let safe = String(host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return directory.appendingPathComponent("\(safe).png")
    }

    // MARK: - Off the main thread

    /// Reads at most `byteLimit` bytes; anything longer is not an icon.
    private nonisolated static func download(_ url: URL, with session: URLSession) async -> Data? {
        guard let (bytes, response) = try? await session.bytes(from: url),
              ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400,
              response.expectedContentLength <= Int64(byteLimit)
        else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > byteLimit { return nil }
            }
        } catch {
            return nil
        }
        return data
    }

    private nonisolated static func thumbnail(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source)
    }

    private nonisolated static func thumbnail(fromFile url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: source)
    }

    private nonisolated static func thumbnail(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
