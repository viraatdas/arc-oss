import RadianCore
import SwiftUI

struct SidebarView: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let space = store.currentSpace
        let incoming = store.spaceTransitionEdge
        let outgoing: Edge = incoming == .trailing ? .leading : .trailing

        VStack(spacing: 0) {
            SidebarTopBar()
            AddressPill()
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            ScrollView(.vertical) {
                SpaceContents(space: space)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            // A new identity per space is what lets one slide out while the next slides in.
            .id(space.id)
            .transition(
                .asymmetric(
                    insertion: .move(edge: incoming).combined(with: .opacity),
                    removal: .move(edge: outgoing).combined(with: .opacity)
                )
            )

            SpaceSwitcher()
        }
        .clipped()
        .animation(.snappy(duration: 0.28), value: space.id)
    }
}

/// The row beside the traffic lights: sidebar toggle and page navigation.
private struct SidebarTopBar: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let session = store.selectedSession

        HStack(spacing: 2) {
            Spacer(minLength: 0)
            ChromeButton(symbol: "sidebar.left", help: "Hide Sidebar (⌘S)") {
                store.toggleSidebar()
            }
            ChromeButton(symbol: "arrow.left", help: "Back (⌘[)", isEnabled: session?.canGoBack == true) {
                session?.goBack()
            }
            ChromeButton(symbol: "arrow.right", help: "Forward (⌘])", isEnabled: session?.canGoForward == true) {
                session?.goForward()
            }
            if session?.isLoading == true {
                ChromeButton(symbol: "xmark", help: "Stop (⌘.)") { session?.stop() }
            } else {
                ChromeButton(symbol: "arrow.clockwise", help: "Reload (⌘R)", isEnabled: session != nil) {
                    session?.reload()
                }
            }
        }
        // Leaves room for the traffic lights, which the window draws over this row.
        .padding(.leading, 76)
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(WindowDragArea())
    }
}

/// Shows where the current tab is. Clicking it opens the command bar to go somewhere else.
private struct AddressPill: View {
    @Environment(BrowserStore.self) private var store
    @State private var isHovering = false

    var body: some View {
        let url = store.selectedItem?.url

        Button {
            store.presentCommandBar(.currentTab)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol(for: url))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(label(for: url))
                    .font(.system(size: 13))
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(isHovering ? 0.13 : 0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Search or enter address (⌘L)")
        .contextMenu {
            if let id = store.selectedTabID {
                Button("Copy Link") { store.copyLink(of: id) }
            }
        }
    }

    private func label(for url: URL?) -> String {
        guard let url else { return "Search or enter address" }
        let host = BrowsingHistory.bareHost(url)
        return host.isEmpty ? url.absoluteString : host
    }

    private func symbol(for url: URL?) -> String {
        switch url?.scheme?.lowercased() {
        case "https": "lock.fill"
        case "http": "lock.open.fill"
        case .some: "doc.fill"
        case .none: "magnifyingglass"
        }
    }
}

/// Everything that belongs to one space: favorites, pinned items, then today's tabs.
private struct SpaceContents: View {
    @Environment(BrowserStore.self) private var store
    let space: Space

    var body: some View {
        let favorites = store.state.favorites(forSpace: space.id)

        VStack(alignment: .leading, spacing: 2) {
            if !favorites.isEmpty {
                FavoritesGrid(items: favorites, spaceID: space.id)
                    .padding(.bottom, 10)
            }

            SpaceHeader(space: space)

            ForEach(space.pinned) { item in
                SidebarNode(item: item, section: .pinned, spaceID: space.id, depth: 0)
            }
            DropZone(
                destination: MoveDestination(spaceID: space.id, section: .pinned, placement: .end),
                height: space.pinned.isEmpty ? 30 : 8,
                hint: space.pinned.isEmpty ? "Drag tabs here to pin them" : nil
            )

            Rectangle()
                .fill(.primary.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            NewTabRow()

            ForEach(space.tabs) { item in
                SidebarNode(item: item, section: .tabs, spaceID: space.id, depth: 0)
            }
            DropZone(
                destination: MoveDestination(spaceID: space.id, section: .tabs, placement: .end),
                height: 44,
                hint: nil
            )
        }
    }
}

private struct SpaceHeader: View {
    @Environment(BrowserStore.self) private var store
    let space: Space
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            SpaceIconView(icon: space.icon, size: 12)
            Text(space.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovering ? 1 : 0)
            .accessibilityLabel("\(space.name) options")
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 28)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { menuItems }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Edit Space…") { store.editingSpaceID = space.id }
        Button("New Folder") { store.newFolder() }
        Divider()
        Button("New Space") { store.newSpace() }
        Button("Delete Space…", role: .destructive) { store.requestDeleteSpace(space.id) }
            .disabled(store.state.spaces.count < 2)
    }
}

private struct NewTabRow: View {
    @Environment(BrowserStore.self) private var store
    @State private var isHovering = false

    var body: some View {
        Button {
            store.presentCommandBar(.newTab)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16, height: 16)
                Text("New Tab")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(isHovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("New Tab (⌘T)")
    }
}

/// The row of space icons along the bottom of the sidebar. With more spaces than fit, the icons
/// scroll sideways and the buttons at either end stay put.
private struct SpaceSwitcher: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            ChromeButton(symbol: "archivebox", help: "Archive (⇧⌘A)") {
                store.isArchivePresented = true
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(store.state.spaces) { space in
                            SpaceSwitcherIcon(space: space).id(space.id)
                        }
                    }
                    .padding(.horizontal, 4)
                    .frame(minWidth: 0)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.center)
                .onChange(of: store.state.currentSpaceID) { _, id in
                    withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .frame(maxWidth: .infinity)
            ChromeButton(symbol: "plus", help: "New Space") {
                store.newSpace()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
    }
}

private struct SpaceSwitcherIcon: View {
    @Environment(BrowserStore.self) private var store
    let space: Space

    @State private var isDropTarget = false

    var body: some View {
        let isCurrent = space.id == store.state.currentSpaceID

        Button {
            store.switchSpace(to: space.id)
        } label: {
            SpaceIconView(icon: space.icon, size: 13)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.primary.opacity(isCurrent || isDropTarget ? 0.12 : 0)))
                .overlay(Circle().strokeBorder(Color.accentColor.opacity(isDropTarget ? 0.9 : 0), lineWidth: 2))
                .opacity(isCurrent || isDropTarget ? 1 : 0.45)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(space.name)
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        // Dropping a tab on a space's icon moves it into that space.
        .onDrop(
            of: [.radianSidebarItem],
            delegate: SidebarDropDelegate(isTargeted: $isDropTarget) { id in
                store.moveToSpace(id, spaceID: space.id)
            }
        )
        .contextMenu {
            Button("Edit Space…") { store.editingSpaceID = space.id }
            Button("Delete Space…", role: .destructive) { store.requestDeleteSpace(space.id) }
                .disabled(store.state.spaces.count < 2)
        }
    }
}
