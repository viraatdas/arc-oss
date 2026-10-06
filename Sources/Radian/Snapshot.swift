import AppKit
import RadianCore
import SwiftUI
import WebKit

/// Renders the browser window to a PNG without ever putting a window on screen.
///
///     Radian --snapshot out.png [--size 1320x860] [--dark] [--wait 4]
///            [--import-arc StorableSidebar.json] [--space 2] [--select 2]
///            [--command-bar [query]] [--split 3] [--hide-sidebar]
///
/// This exists for screenshots and for checking layout on machines with no usable display (CI).
/// It is a real instance of the app driving real web views, so point `RADIAN_DATA_DIR` at a
/// scratch directory. Window materials do not render off screen, so translucency appears flat.
@MainActor
enum Snapshot {
    struct Options {
        var output: URL
        var size = NSSize(width: 1320, height: 860)
        var isDark = false
        var wait: TimeInterval = 4
        var arcSidebar: URL?
        var spacePosition: Int?
        var selectPosition: Int?
        var commandBarQuery: String?
        var splitPosition: Int?
        var hidesSidebar = false
    }

    /// Parses the command line. Returns nil when `--snapshot` is absent, which is the normal case.
    static func options(from arguments: [String]) -> Options? {
        var remaining = Array(arguments.dropFirst())
        func value(after flag: String) -> String? {
            guard let index = remaining.firstIndex(of: flag) else { return nil }
            remaining.remove(at: index)
            guard index < remaining.count, !remaining[index].hasPrefix("--") else { return "" }
            return remaining.remove(at: index)
        }
        guard let output = value(after: "--snapshot") else { return nil }
        guard !output.isEmpty else {
            print(usage)
            exit(2)
        }

        var options = Options(output: URL(fileURLWithPath: output))
        if let size = value(after: "--size") {
            let parts = size.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { options.size = NSSize(width: parts[0], height: parts[1]) }
        }
        if let wait = value(after: "--wait").flatMap(Double.init) { options.wait = wait }
        if let path = value(after: "--import-arc"), !path.isEmpty { options.arcSidebar = URL(fileURLWithPath: path) }
        if let position = value(after: "--space").flatMap(Int.init) { options.spacePosition = position - 1 }
        if let position = value(after: "--select").flatMap(Int.init) { options.selectPosition = position - 1 }
        options.commandBarQuery = value(after: "--command-bar")
        options.isDark = value(after: "--dark") != nil
        if let position = value(after: "--split").flatMap(Int.init) { options.splitPosition = position - 1 }
        options.hidesSidebar = value(after: "--hide-sidebar") != nil
        return options
    }

    static let usage = """
    usage: Radian --snapshot <out.png> [options]

      --size WxH             window size in points (default 1320x860)
      --dark                 dark appearance
      --wait SECONDS         time for pages to load before capturing (default 4)
      --import-arc FILE      import an Arc StorableSidebar.json first
      --space N              show the Nth space
      --select N             select the Nth tab, counting from the top of the sidebar
      --split N              open the Nth tab in split view beside the selected one
      --command-bar [TEXT]   show the command bar, optionally with TEXT typed into it
      --hide-sidebar         hide the sidebar

    Set RADIAN_DATA_DIR to a scratch directory: snapshot mode reads and writes app state.
    """

    static func run(_ options: Options) {
        let store = BrowserStore()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: options.size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: options.isDark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: RootView().environment(store))
        host.frame = NSRect(origin: .zero, size: options.size)
        window.contentView = host
        store.window = window

        if let arcSidebar = options.arcSidebar {
            do {
                let (stats, _) = try store.importFromArc(at: arcSidebar)
                print("imported: \(stats)")
            } catch {
                fail("import failed: \(error.localizedDescription)")
            }
        }
        if let position = options.spacePosition { store.selectSpace(atPosition: position) }
        store.start()
        if let position = options.selectPosition { store.selectTab(atPosition: position) }
        if let position = options.splitPosition {
            let tabs = store.state.visibleTabs(inSpace: store.state.currentSpaceID)
            if tabs.indices.contains(position) { store.openInSplit(tabs[position].id) }
        } else if store.isSplit {
            store.closeSplit()
        }
        if options.hidesSidebar { store.isSidebarVisible = false }
        if let query = options.commandBarQuery {
            store.presentCommandBar(.newTab, initialText: query)
        }

        Task {
            try? await Task.sleep(for: .seconds(options.wait))
            await capture(host: host, store: store, to: options.output)
            store.saveNow()
            exit(0)
        }
    }

    private static func capture(host: NSView, store: BrowserStore, to output: URL) async {
        host.layoutSubtreeIfNeeded()

        // Web content is drawn by another process and is not part of the view's own drawing. So
        // each page is captured on its own and swapped in as a still image, which lets the page
        // and whatever sits over it (command bar, find bar) be captured together in one pass.
        var stills: [UUID: NSImage] = [:]
        for session in [store.selectedSession, store.splitSession].compactMap({ $0 }) {
            let webView = session.webView
            guard webView.window != nil, webView.bounds.width > 0 else { continue }
            if let image = try? await webView.takeSnapshot(configuration: nil) {
                stills[session.id] = image
            } else {
                print("warning: no snapshot for \(webView.url?.absoluteString ?? "tab")")
            }
        }
        let pageCount = stills.count
        store.freezePages(stills)
        try? await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()

        guard let chrome = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fail("could not allocate the bitmap")
        }
        host.cacheDisplay(in: host.bounds, to: chrome)

        let bounds = host.bounds
        let composite = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
            chrome.draw(in: rect)
            return true
        }

        guard let tiff = composite.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            fail("could not encode the image")
        }
        do {
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try png.write(to: output, options: .atomic)
            print("wrote \(output.path) (\(Int(bounds.width))x\(Int(bounds.height)) pt, \(pageCount) page(s))")
        } catch {
            fail("could not write \(output.path): \(error.localizedDescription)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("snapshot: \(message)\n".utf8))
        exit(1)
    }
}
