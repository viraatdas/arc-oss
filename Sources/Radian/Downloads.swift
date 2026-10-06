import AppKit
import WebKit

/// Receives every download. It belongs to the store rather than to a tab, so a download keeps
/// going when the tab that started it closes, including tabs that existed only to download.
@MainActor
final class DownloadCenter: NSObject, WKDownloadDelegate {
    /// Shows a short status message: text, then an SF Symbol name.
    var report: (String, String) -> Void = { _, _ in }

    private var destinations: [ObjectIdentifier: URL] = [:]

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destination = DownloadCenter.uniqueDestination(in: directory, filename: suggestedFilename)
        destinations[ObjectIdentifier(download)] = destination
        report("Downloading \(destination.lastPathComponent)", "arrow.down.circle.fill")
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        report("Downloaded \(destination.lastPathComponent)", "arrow.down.circle.fill")
        // Makes the Downloads stack in the Dock bounce, as it does for other browsers.
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.DownloadFileFinished"),
            object: destination.path
        )
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        report("Download failed", "exclamationmark.triangle.fill")
    }

    /// Never overwrites: "report.pdf" becomes "report 2.pdf" if the name is taken.
    static func uniqueDestination(in directory: URL, filename: String) -> URL {
        let safeName = (filename as NSString).lastPathComponent
        let name = safeName.isEmpty || safeName == "." || safeName == ".." ? "download" : safeName
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = pathExtension.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(pathExtension)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }
}
