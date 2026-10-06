import AppKit
import Observation

/// Site icons, one per host, cached in memory and on disk.
@MainActor
@Observable
final class FaviconStore {
    private var images: [String: NSImage] = [:]

    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let session: URLSession

    init(directory: URL) {
        self.directory = directory
        // Icon requests carry no cookies and leave nothing behind but the icon.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
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
            guard let image = await fetch(iconURL) else { return }
            store(image, forHost: host)
        }
    }

    private func loadDefaultIcon(host: String, scheme: String) async {
        if let data = try? Data(contentsOf: fileURL(forHost: host)), let cached = NSImage(data: data) {
            images[host] = cached
            return
        }
        guard scheme == "http" || scheme == "https",
              let url = URL(string: "\(scheme)://\(host)/favicon.ico"),
              let image = await fetch(url)
        else { return }
        // A page-declared icon may have landed while this request was in flight; it wins.
        if images[host] == nil {
            store(image, forHost: host)
        }
    }

    private func fetch(_ url: URL) async -> NSImage? {
        guard let (data, response) = try? await session.data(from: url),
              ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400,
              let image = NSImage(data: data), image.isValid, image.size.width > 0
        else { return nil }
        return image
    }

    private func store(_ image: NSImage, forHost host: String) {
        images[host] = image
        guard let png = FaviconStore.pngData(image, side: 64) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: fileURL(forHost: host), options: .atomic)
    }

    private func fileURL(forHost host: String) -> URL {
        let safe = String(host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return directory.appendingPathComponent("\(safe).png")
    }

    private static func pngData(_ image: NSImage, side: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        return bitmap.representation(using: .png, properties: [:])
    }
}
