import RadianCore
import SwiftUI
import UniformTypeIdentifiers

private let rowShape = RoundedRectangle(cornerRadius: 8, style: .continuous)

extension UTType {
    /// A sidebar item being dragged inside Radian. Declared in Info.plist.
    static let radianSidebarItem = UTType(exportedAs: "io.github.viraatdas.radian.sidebar-item")
}

/// What a sidebar row puts on the drag pasteboard: its id under Radian's own type, which nothing
/// else reads, and for a tab its address, so dropping it on another app or a page gives the link.
func dragProvider(for item: SidebarItem) -> NSItemProvider {
    let provider = NSItemProvider(
        item: Data(item.id.uuidString.utf8) as NSData,
        typeIdentifier: UTType.radianSidebarItem.identifier
    )
    if !item.isFolder, let url = item.url ?? item.homeURL {
        provider.registerObject(url as NSURL, visibility: .all)
    }
    provider.suggestedName = item.displayTitle
    return provider
}

/// One entry in the pinned or unpinned list. Folders draw their children beneath themselves.
struct SidebarNode: View {
    let item: SidebarItem
    let section: SidebarSection
    let spaceID: UUID
    let depth: Int

    var body: some View {
        if item.isFolder {
            FolderRow(item: item, spaceID: spaceID, depth: depth)
            if item.isExpanded {
                ForEach(item.children) { child in
                    SidebarNode(item: child, section: section, spaceID: spaceID, depth: depth + 1)
                }
            }
        } else {
            TabRow(item: item, section: section, spaceID: spaceID, depth: depth)
        }
    }
}

private struct TabRow: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let item: SidebarItem
    let section: SidebarSection
    let spaceID: UUID
    let depth: Int

    @State private var isHovering = false
    @State private var isDropTarget = false

    var body: some View {
        let isSelected = store.isOnScreen(item.id)
        let isRenaming = store.renamingItemID == item.id

        HStack(spacing: 9) {
            // A pinned tab keeps the icon of the site it is pinned to, wherever it has wandered.
            FaviconView(url: item.homeURL ?? item.url)
            if isRenaming {
                RenameField(item: item)
            } else {
                Text(item.displayTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if isHovering, !isRenaming {
                Button {
                    store.closeTab(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.primary.opacity(0.1)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(closeLabel)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .frame(height: 34)
        .background(rowShape.fill(fill(isSelected: isSelected)))
        .shadow(color: .black.opacity(isSelected && scheme == .light ? 0.1 : 0), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { store.select(item.id) }
        .onHover { isHovering = $0 }
        .padding(.leading, CGFloat(depth) * 16)
        .overlay(alignment: .top) { InsertionLine(isVisible: isDropTarget) }
        .onDrag { dragProvider(for: item) }
        .onDrop(
            of: [.radianSidebarItem],
            delegate: SidebarDropDelegate(
                store: store,
                destination: MoveDestination(spaceID: spaceID, section: section, placement: .before(item.id)),
                isTargeted: $isDropTarget
            )
        )
        .contextMenu { TabContextMenu(item: item, section: section, spaceID: spaceID) }
        // While renaming, the text field has to stay reachable; otherwise the row is one button.
        .accessibilityElement(children: isRenaming ? .contain : .ignore)
        .accessibilityLabel(item.displayTitle)
        .accessibilityValue(item.url.map(BrowsingHistory.bareHost) ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { store.select(item.id) }
        .accessibilityAction(named: closeLabel) { store.closeTab(item.id) }
    }

    private var closeLabel: String { section == .tabs ? "Close Tab" : "Unload Tab" }

    private func fill(isSelected: Bool) -> Color {
        if isSelected { return scheme == .dark ? .white.opacity(0.18) : .white.opacity(0.9) }
        return .primary.opacity(isHovering ? 0.08 : 0)
    }
}

private struct FolderRow: View {
    @Environment(BrowserStore.self) private var store
    let item: SidebarItem
    let spaceID: UUID
    let depth: Int

    @State private var isHovering = false
    @State private var isDropTarget = false

    var body: some View {
        let isRenaming = store.renamingItemID == item.id
        let count = item.children.allTabs.count

        HStack(spacing: 9) {
            Image(systemName: item.isExpanded ? "folder.fill" : "folder")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            if isRenaming {
                RenameField(item: item)
            } else {
                Text(item.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !item.isExpanded, count > 0 {
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 4)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .frame(height: 34)
        .background(rowShape.fill(.primary.opacity(isDropTarget ? 0.16 : isHovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { store.toggleFolder(item.id) }
        .onHover { isHovering = $0 }
        .padding(.leading, CGFloat(depth) * 16)
        .onDrag { dragProvider(for: item) }
        .onDrop(
            of: [.radianSidebarItem],
            delegate: SidebarDropDelegate(
                store: store,
                destination: MoveDestination(spaceID: spaceID, section: .pinned, placement: .inFolder(item.id)),
                isTargeted: $isDropTarget
            )
        )
        .contextMenu {
            Button("Rename…") { store.renamingItemID = item.id }
            Button(item.isExpanded ? "Collapse" : "Expand") { store.toggleFolder(item.id) }
            Divider()
            Button("Delete Folder…", role: .destructive) { store.requestDeleteFolder(item.id) }
        }
        .accessibilityElement(children: isRenaming ? .contain : .ignore)
        .accessibilityLabel("\(item.displayTitle), folder")
        .accessibilityValue("\(item.isExpanded ? "Expanded" : "Collapsed"), \(count) \(count == 1 ? "tab" : "tabs")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.toggleFolder(item.id) }
    }
}

struct FavoritesGrid: View {
    @Environment(BrowserStore.self) private var store
    let items: [SidebarItem]
    let spaceID: UUID

    @State private var isDropTarget = false

    private let columns = [GridItem(.adaptive(minimum: 50, maximum: 140), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(items) { item in
                FavoriteTile(item: item, spaceID: spaceID)
            }
        }
        // Gaps between tiles and the space after the last one add to the end of the grid.
        .contentShape(Rectangle())
        .onDrop(
            of: [.radianSidebarItem],
            delegate: SidebarDropDelegate(
                store: store,
                destination: MoveDestination(spaceID: spaceID, section: .favorites, placement: .end),
                isTargeted: $isDropTarget
            )
        )
    }
}

private struct FavoriteTile: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let item: SidebarItem
    let spaceID: UUID

    @State private var isHovering = false
    @State private var isDropTarget = false

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        let isSelected = store.isOnScreen(item.id)

        FaviconView(url: item.homeURL ?? item.url, size: 18)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(shape.fill(fill(isSelected: isSelected)))
            .overlay(shape.strokeBorder(Color.accentColor.opacity(isDropTarget ? 0.8 : 0), lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture { store.select(item.id) }
            .onHover { isHovering = $0 }
            .help(item.displayTitle)
            .onDrag { dragProvider(for: item) }
            .onDrop(
                of: [.radianSidebarItem],
                delegate: SidebarDropDelegate(
                    store: store,
                    destination: MoveDestination(spaceID: spaceID, section: .favorites, placement: .before(item.id)),
                    isTargeted: $isDropTarget
                )
            )
            .contextMenu { TabContextMenu(item: item, section: .favorites, spaceID: spaceID) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.displayTitle)
            .accessibilityValue("Favorite")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { store.select(item.id) }
    }

    private func fill(isSelected: Bool) -> Color {
        if isSelected { return scheme == .dark ? .white.opacity(0.22) : .white.opacity(0.9) }
        return .primary.opacity(isHovering ? 0.14 : 0.08)
    }
}

private struct TabContextMenu: View {
    @Environment(BrowserStore.self) private var store
    let item: SidebarItem
    let section: SidebarSection
    let spaceID: UUID

    var body: some View {
        Button(section == .tabs ? "Pin Tab" : "Unpin Tab") { store.togglePin(item.id) }
        if section != .favorites {
            Button("Add to Favorites") { store.addToFavorites(item.id) }
        }
        Button("Open in Split View") { store.openInSplit(item.id) }
            .disabled(store.selectedTabID == nil || store.selectedTabID == item.id)
        Divider()
        Button("Rename…") { store.renamingItemID = item.id }
            .disabled(section == .favorites)
        Button("Duplicate") {
            if let url = item.url { store.openTab(url: url, inBackground: true) }
        }
        Button("Copy Link") { store.copyLink(of: item.id) }
        if section != .tabs, item.homeURL != nil, item.url != item.homeURL {
            Divider()
            Button("Return to Pinned Page") { store.resetToHome(item.id) }
            Button("Pin This Page Instead") { store.adoptCurrentURLAsHome(item.id) }
        }
        if store.state.spaces.count > 1 {
            Menu("Move to Space") {
                ForEach(store.state.spaces.filter { $0.id != spaceID }) { space in
                    Button(space.name) { store.moveToSpace(item.id, spaceID: space.id) }
                }
            }
        }
        Divider()
        if section == .tabs {
            Button("Close Tab") { store.closeTab(item.id) }
        } else {
            // Recoverable from the archive, so it does not ask first.
            Button(section == .favorites ? "Remove from Favorites" : "Remove Pinned Tab", role: .destructive) {
                store.deleteItem(item.id)
            }
        }
    }
}

/// Inline editor shown in place of a row's title.
private struct RenameField: View {
    @Environment(BrowserStore.self) private var store
    let item: SidebarItem

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(item.isFolder ? "Folder name" : "Tab name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($isFocused)
            .onSubmit { store.rename(item.id, to: text) }
            .onExitCommand { store.renamingItemID = nil }
            .onAppear {
                text = item.displayTitle
                isFocused = true
            }
            .onChange(of: isFocused) { _, focused in
                // Clicking away commits, the same as pressing Return.
                if !focused, store.renamingItemID == item.id {
                    store.rename(item.id, to: text)
                }
            }
    }
}

private struct InsertionLine: View {
    let isVisible: Bool

    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 6)
            .offset(y: -2)
            .opacity(isVisible ? 1 : 0)
    }
}

/// Empty space at the end of a section that accepts drops, so a tab can be dragged to the end of
/// a list or into a section that has nothing in it yet.
struct DropZone: View {
    @Environment(BrowserStore.self) private var store
    let destination: MoveDestination
    let height: CGFloat
    let hint: String?

    @State private var isDropTarget = false

    var body: some View {
        ZStack {
            if let hint {
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(rowShape.fill(.primary.opacity(isDropTarget && hint != nil ? 0.1 : 0)))
        .overlay(alignment: .top) { InsertionLine(isVisible: isDropTarget && hint == nil).offset(y: 2) }
        .contentShape(Rectangle())
        .onDrop(
            of: [.radianSidebarItem],
            delegate: SidebarDropDelegate(store: store, destination: destination, isTargeted: $isDropTarget)
        )
        .accessibilityHidden(hint == nil)
    }
}

/// Handles a drop of a sidebar item. The id is read from the drop itself, so only drags that
/// started on a sidebar row are accepted, and each drop acts on exactly what was dragged.
struct SidebarDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let perform: @MainActor (UUID) -> Void

    /// Moves the dropped item to `destination`.
    init(store: BrowserStore, destination: MoveDestination, isTargeted: Binding<Bool>) {
        self.init(isTargeted: isTargeted) { id in store.move(id, to: destination) }
    }

    init(isTargeted: Binding<Bool>, perform: @escaping @MainActor (UUID) -> Void) {
        _isTargeted = isTargeted
        self.perform = perform
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.radianSidebarItem])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let provider = info.itemProviders(for: [.radianSidebarItem]).first else { return false }
        let perform = self.perform
        provider.loadDataRepresentation(forTypeIdentifier: UTType.radianSidebarItem.identifier) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else {
                return
            }
            Task { @MainActor in perform(id) }
        }
        return true
    }
}
