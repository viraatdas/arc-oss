import AppKit
import RadianCore
import SwiftUI

/// Something the command bar can run that is not a page.
struct CommandAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var shortcut: String = ""
    let perform: @MainActor (BrowserStore) -> Void

    @MainActor static let all: [CommandAction] = [
        CommandAction(id: "pin", title: "Pin or Unpin Tab", symbol: "pin", shortcut: "⌘D") { store in
            if let id = store.selectedTabID { store.togglePin(id) }
        },
        CommandAction(id: "favorite", title: "Add Tab to Favorites", symbol: "star") { store in
            if let id = store.selectedTabID { store.addToFavorites(id) }
        },
        CommandAction(id: "copy-link", title: "Copy Link", symbol: "link", shortcut: "⇧⌘C") { store in
            if let id = store.selectedTabID { store.copyLink(of: id) }
        },
        CommandAction(id: "split", title: "Toggle Split View", symbol: "rectangle.split.2x1", shortcut: "⌃⇧=") { store in
            store.toggleSplit()
        },
        CommandAction(id: "new-folder", title: "New Folder", symbol: "folder.badge.plus") { store in
            store.newFolder()
        },
        CommandAction(id: "new-space", title: "New Space", symbol: "plus.square.on.square") { store in
            store.newSpace()
        },
        CommandAction(id: "edit-space", title: "Edit Space", symbol: "paintpalette") { store in
            store.editingSpaceID = store.state.currentSpaceID
        },
        CommandAction(id: "sidebar", title: "Toggle Sidebar", symbol: "sidebar.left", shortcut: "⌘S") { store in
            store.toggleSidebar()
        },
        CommandAction(id: "archive", title: "View Archive", symbol: "archivebox", shortcut: "⇧⌘A") { store in
            store.isArchivePresented = true
        },
        CommandAction(id: "reopen", title: "Reopen Closed Tab", symbol: "arrow.uturn.backward", shortcut: "⇧⌘T") { store in
            store.reopenClosedTab()
        },
        CommandAction(id: "import-arc", title: "Import from Arc", symbol: "square.and.arrow.down") { _ in
            NSApp.sendAction(#selector(AppDelegate.importFromArc(_:)), to: nil, from: nil)
        },
    ] + SearchEngine.allCases.map { engine in
        CommandAction(id: "search-\(engine.rawValue)", title: "Search with \(engine.displayName)", symbol: "magnifyingglass") { store in
            store.setSearchEngine(engine)
        }
    }
}

enum CommandResult: Identifiable {
    case open(InputResolution)
    case switchToTab(SidebarItem, spaceName: String)
    case history(HistoryEntry)
    case action(CommandAction)

    var id: String {
        switch self {
        case .open(let resolution): "open:\(resolution.url.absoluteString)"
        case .switchToTab(let item, _): "tab:\(item.id.uuidString)"
        case .history(let entry): "history:\(entry.url.absoluteString)"
        case .action(let action): "action:\(action.id)"
        }
    }
}

extension BrowserStore {
    /// What the command bar lists for a query. The first result is what Return does.
    func commandResults(for query: String) -> [CommandResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return suggestionsForEmptyQuery() }

        var results: [CommandResult] = []
        var listedURLs: Set<String> = []
        func list(_ result: CommandResult, url: URL?) {
            if let url {
                guard listedURLs.insert(BrowsingHistory.displayURL(url)).inserted else { return }
            }
            results.append(result)
        }

        let resolution = URLResolver.resolve(trimmed, engine: state.settings.searchEngine)
        if let resolution, !resolution.isSearch {
            list(.open(resolution), url: resolution.url)
        } else if let completion = history.bestHostMatch(forPrefix: trimmed) {
            // "gith" + Return goes to github.com when that is somewhere the user actually goes.
            list(.history(completion), url: completion.url)
        }
        if let resolution, resolution.isSearch {
            results.append(.open(resolution))
        }

        for (item, spaceName) in openTabs(matching: trimmed).prefix(3) {
            list(.switchToTab(item, spaceName: spaceName), url: nil)
        }

        let actions = CommandAction.all
            .compactMap { action in FuzzyMatch.score(query: trimmed, candidate: action.title).map { (action, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
        results.append(contentsOf: actions.map { .action($0.0) })

        for entry in history.search(trimmed, limit: 5) {
            list(.history(entry), url: entry.url)
        }
        return results
    }

    /// With nothing typed, offer the other tabs in this space and the most useful commands.
    private func suggestionsForEmptyQuery() -> [CommandResult] {
        let space = currentSpace
        let recent = (space.pinned.allTabs + space.tabs.allTabs)
            .filter { $0.id != selectedTabID }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
            .prefix(5)
            .map { CommandResult.switchToTab($0, spaceName: space.name) }
        return recent + CommandAction.all.prefix(5).map { .action($0) }
    }

    private func openTabs(matching query: String) -> [(SidebarItem, String)] {
        var matches: [(item: SidebarItem, spaceName: String, score: Int)] = []
        // Favorites are shared by every space on a profile, so they are listed once, with this space.
        let favorites = state.favorites(forSpace: state.currentSpaceID).allTabs
        for space in state.spaces {
            let tabs = (space.id == state.currentSpaceID ? favorites : []) + space.pinned.allTabs + space.tabs.allTabs
            for item in tabs where item.id != selectedTabID {
                let scores = [
                    FuzzyMatch.score(query: query, candidate: item.displayTitle),
                    item.url.flatMap { FuzzyMatch.score(query: query, candidate: BrowsingHistory.displayURL($0)) },
                ]
                guard let best = scores.compactMap({ $0 }).max() else { continue }
                // Tabs in the space being looked at are the likelier target.
                matches.append((item, space.name, best + (space.id == state.currentSpaceID ? 50 : 0)))
            }
        }
        return matches.sorted { $0.score > $1.score }.map { ($0.item, $0.spaceName) }
    }

    func perform(_ result: CommandResult, mode: CommandBarRequest.Mode) {
        dismissCommandBar()
        switch result {
        case .open(let resolution):
            open(resolution.url, mode: mode)
        case .history(let entry):
            open(entry.url, mode: mode)
        case .switchToTab(let item, _):
            // Only a tab from this space can sit in the split; anything else is a plain switch.
            if mode == .splitPane, state.visibleTabsIncludingCollapsed(inSpace: state.currentSpaceID).contains(item.id) {
                openInSplit(item.id)
            } else {
                select(item.id)
            }
        case .action(let action):
            action.perform(self)
        }
    }
}

// MARK: - Views

struct CommandBarOverlay: View {
    @Environment(BrowserStore.self) private var store
    let request: CommandBarRequest

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.14)
                .contentShape(Rectangle())
                .onTapGesture { store.dismissCommandBar() }
            CommandBarPanel(request: request)
                .padding(.top, 130)
                .padding(.horizontal, 24)
        }
    }
}

private struct CommandBarPanel: View {
    @Environment(BrowserStore.self) private var store
    let request: CommandBarRequest

    @State private var query: String
    @State private var selection = 0

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    init(request: CommandBarRequest) {
        self.request = request
        _query = State(initialValue: request.initialText)
    }

    var body: some View {
        let results = store.commandResults(for: query)

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                CommandField(
                    text: $query,
                    placeholder: placeholder,
                    selectsAllOnFocus: request.mode == .currentTab,
                    onMove: { delta in
                        guard !results.isEmpty else { return }
                        selection = min(max(selection + delta, 0), results.count - 1)
                    },
                    onSubmit: {
                        guard results.indices.contains(selection) else { return }
                        store.perform(results[selection], mode: request.mode)
                    },
                    onCancel: { store.dismissCommandBar() }
                )
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            if !results.isEmpty {
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        CommandRow(result: result, isSelected: index == selection)
                            .onTapGesture { store.perform(result, mode: request.mode) }
                    }
                }
                .padding(6)
            }
        }
        .frame(maxWidth: 640)
        .background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 14)
        .onChange(of: query) { selection = 0 }
    }

    private var symbol: String {
        switch request.mode {
        case .newTab: "plus"
        case .currentTab: "magnifyingglass"
        case .splitPane: "rectangle.split.2x1"
        }
    }

    private var placeholder: String {
        switch request.mode {
        case .newTab: "Search or enter address"
        case .currentTab: "Go somewhere else"
        case .splitPane: "Open beside this tab"
        }
    }
}

private struct CommandRow: View {
    @Environment(BrowserStore.self) private var store
    let result: CommandResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            icon.frame(width: 18, height: 18)
            Text(title)
                .font(.system(size: 14))
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(hint)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : .clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch result {
        case .open(let resolution):
            if resolution.isSearch {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            } else {
                FaviconView(url: resolution.url)
            }
        case .switchToTab(let item, _):
            FaviconView(url: item.homeURL ?? item.url)
        case .history(let entry):
            FaviconView(url: entry.url)
        case .action(let action):
            Image(systemName: action.symbol).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch result {
        case .open(.search(_, let query)): query
        case .open(.url(let url)): BrowsingHistory.displayURL(url)
        case .switchToTab(let item, _): item.displayTitle
        case .history(let entry): entry.title.isEmpty ? BrowsingHistory.displayURL(entry.url) : entry.title
        case .action(let action): action.title
        }
    }

    private var subtitle: String? {
        switch result {
        case .open(let resolution):
            resolution.isSearch ? "Search \(store.state.settings.searchEngine.displayName)" : nil
        case .switchToTab(let item, _):
            item.url.map(BrowsingHistory.bareHost)
        case .history(let entry):
            entry.title.isEmpty ? nil : BrowsingHistory.displayURL(entry.url)
        case .action:
            nil
        }
    }

    private var hint: String {
        switch result {
        case .open, .history: isSelected ? "↩" : ""
        case .switchToTab(_, let spaceName):
            spaceName == store.currentSpace.name ? "Switch to Tab" : "Switch to Tab · \(spaceName)"
        case .action(let action): action.shortcut
        }
    }
}

/// The command bar's text field. AppKit is used directly so the field reliably takes focus from
/// the web view and so the arrow keys can drive the result list while typing continues.
private struct CommandField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var selectsAllOnFocus: Bool
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 19)
        field.placeholderString = placeholder
        field.stringValue = text
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.selectsAllOnFocus = selectsAllOnFocus
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandField

        init(_ parent: CommandField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }
}

private final class FocusingTextField: NSTextField {
    var selectsAllOnFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Deferred a turn: the field is not yet able to become first responder while it is being
        // installed in the window.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            guard let editor = self.currentEditor() else { return }
            if self.selectsAllOnFocus {
                editor.selectAll(nil)
            } else {
                editor.selectedRange = NSRange(location: (self.stringValue as NSString).length, length: 0)
            }
        }
    }
}
