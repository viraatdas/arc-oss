import AppKit
import SwiftUI

@MainActor
final class BrowserWindowController: NSWindowController {
    private let store: BrowserStore
    private var scrollMonitor: Any?
    private var swipe = SwipeTracker()

    init(store: BrowserStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // The content runs edge to edge; the sidebar stands in for the title bar.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Radian"
        window.minSize = NSSize(width: 620, height: 400)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: RootView().environment(store))
        window.center()
        window.setFrameAutosaveName("RadianMainWindow")
        super.init(window: window)

        store.window = window
        store.applyWindowChrome()
        installSwipeMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Two-finger horizontal swipes over the sidebar move between spaces.
    private func installSwipeMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) }
            return event
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard event.window === window, store.isSidebarVisible, store.commandBar == nil,
              event.hasPreciseScrollingDeltas, event.locationInWindow.x <= store.sidebarWidth
        else { return }
        if let direction = swipe.update(with: event) {
            store.cycleSpace(by: direction)
        }
    }
}

/// Turns a stream of trackpad scroll events into at most one "next" or "previous" per gesture.
private struct SwipeTracker {
    private var horizontal: CGFloat = 0
    private var vertical: CGFloat = 0
    private var hasFired = false

    /// Returns +1 or -1 the moment a gesture qualifies as a horizontal swipe, otherwise nil.
    mutating func update(with event: NSEvent) -> Int? {
        if event.phase.contains(.began) {
            horizontal = 0
            vertical = 0
            hasFired = false
        }
        // Momentum after the fingers lift must not trigger a second switch.
        guard event.momentumPhase.isEmpty, !hasFired else { return nil }
        horizontal += event.scrollingDeltaX
        vertical += event.scrollingDeltaY
        guard abs(horizontal) > 70, abs(horizontal) > abs(vertical) * 2.5 else { return nil }
        hasFired = true
        // Content follows the fingers: swiping left reveals the space to the right.
        return horizontal < 0 ? 1 : -1
    }
}
