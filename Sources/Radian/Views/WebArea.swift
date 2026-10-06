import RadianCore
import SwiftUI
import WebKit

/// The page, or two pages side by side when split view is on.
struct WebArea: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            if let primary = store.selectedSession {
                WebCard(session: primary, onCloseSplit: nil)
                if let secondary = store.splitSession, secondary.id != primary.id {
                    WebCard(session: secondary, onCloseSplit: { store.closeSplit() })
                }
            } else {
                EmptyCard()
            }
        }
    }
}

private let cardShape = RoundedRectangle(cornerRadius: 10, style: .continuous)

struct WebCard: View {
    @Environment(BrowserStore.self) private var store
    let session: TabSession
    let onCloseSplit: (() -> Void)?

    var body: some View {
        page
            .overlay(alignment: .top) {
                if session.isLoading {
                    LoadingBar(progress: session.progress)
                }
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 8) {
                    if store.findBarTabID == session.id {
                        FindBar(session: session)
                    }
                    if let onCloseSplit {
                        Button(action: onCloseSplit) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 22, height: 22)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Close Split View")
                        .accessibilityLabel("Close Split View")
                    }
                }
                .padding(10)
            }
            .clipShape(cardShape)
            .background(
                cardShape
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 5, y: 1)
            )
    }
}

extension WebCard {
    @ViewBuilder fileprivate var page: some View {
        if let still = store.pageStills[session.id] {
            Image(nsImage: still).resizable()
        } else {
            WebContainer(webView: session.webView)
        }
    }
}

struct LoadingBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: proxy.size.width * max(progress, 0.06))
                .animation(.easeOut(duration: 0.2), value: progress)
        }
        .frame(height: 2.5)
    }
}

struct EmptyCard: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing open in \(store.currentSpace.name)")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Button("New Tab  ⌘T") {
                store.presentCommandBar(.newTab)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            cardShape
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                .shadow(color: .black.opacity(0.12), radius: 5, y: 1)
        )
    }
}

/// Hosts whichever web view is current. Web views outlive this view: they belong to their tab's
/// session and are moved in and out as the selection changes.
struct WebContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WebHostView { WebHostView() }

    func updateNSView(_ host: WebHostView, context: Context) {
        host.show(webView)
    }
}

final class WebHostView: NSView {
    private weak var current: WKWebView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Clipping here, in AppKit, is what actually rounds the page's corners.
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ webView: WKWebView) {
        guard webView.superview !== self else { return }
        // The previous view may already have moved to another host (the other split pane).
        if let current, current.superview === self {
            current.removeFromSuperview()
        }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        current = webView
    }
}

struct FindBar: View {
    @Environment(BrowserStore.self) private var store
    let session: TabSession

    @State private var text = ""
    @State private var notFound = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in page", text: $text)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($isFocused)
                .onSubmit { find(backwards: false) }
                .onExitCommand { close() }
            Button { find(backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("Previous match")
                .accessibilityLabel("Previous match")
            Button { find(backwards: false) } label: { Image(systemName: "chevron.down") }
                .help("Next match")
                .accessibilityLabel("Next match")
            Button { close() } label: { Image(systemName: "xmark") }
                .help("Done")
                .accessibilityLabel("Close find bar")
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(notFound ? Color.red.opacity(0.7) : Color.primary.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .onAppear { isFocused = true }
        // ⌘F while the bar is already open puts the cursor back in it.
        .onChange(of: store.findFocusRequest) { isFocused = true }
        .onChange(of: text) { notFound = false }
    }

    private func find(backwards: Bool) {
        guard !text.isEmpty else { return }
        Task {
            notFound = !(await session.find(text, backwards: backwards))
        }
    }

    private func close() {
        store.findBarTabID = nil
        store.focusWebContent()
    }
}
