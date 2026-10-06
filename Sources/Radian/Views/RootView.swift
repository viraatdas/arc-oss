import RadianCore
import SwiftUI

struct RootView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.colorScheme) private var systemScheme

    private let gutter: CGFloat = 8

    var body: some View {
        let space = store.currentSpace

        ZStack {
            ThemeBackground(theme: space.theme)

            HStack(spacing: 0) {
                if store.isSidebarVisible {
                    SidebarView()
                        .frame(width: store.sidebarWidth)
                        // Sidebar text follows the theme's brightness, not the system appearance.
                        .environment(\.colorScheme, space.theme.contentScheme(system: systemScheme))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    SidebarResizeHandle(width: gutter)
                }
                WebArea()
                    .padding(.leading, store.isSidebarVisible ? 0 : gutter)
                    .padding([.top, .bottom, .trailing], gutter)
            }

            if let request = store.commandBar {
                CommandBarOverlay(request: request)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .animation(.snappy(duration: 0.22), value: store.isSidebarVisible)
        .animation(.easeOut(duration: 0.12), value: store.commandBar?.id)
        .animation(.snappy(duration: 0.25), value: store.toast)
        .animation(.easeInOut(duration: 0.3), value: space.theme)
        .confirmationDialog(
            store.pendingDeletion.map { store.describe($0).title } ?? "",
            isPresented: deletionBinding,
            presenting: store.pendingDeletion
        ) { deletion in
            Button(store.describe(deletion).action, role: .destructive) { store.confirm(deletion) }
            Button("Cancel", role: .cancel) { store.pendingDeletion = nil }
        } message: { deletion in
            Text(store.describe(deletion).message)
        }
        .sheet(isPresented: archiveBinding) {
            ArchiveView()
        }
        .sheet(isPresented: spaceEditorBinding) {
            if let id = store.editingSpaceID {
                SpaceEditor(spaceID: id)
            }
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { store.pendingDeletion != nil }, set: { if !$0 { store.pendingDeletion = nil } })
    }

    private var archiveBinding: Binding<Bool> {
        Binding(get: { store.isArchivePresented }, set: { store.isArchivePresented = $0 })
    }

    private var spaceEditorBinding: Binding<Bool> {
        Binding(get: { store.editingSpaceID != nil }, set: { if !$0 { store.editingSpaceID = nil } })
    }
}

/// The strip between the sidebar and the page. Dragging it resizes the sidebar.
struct SidebarResizeHandle: View {
    @Environment(BrowserStore.self) private var store
    let width: CGFloat
    @State private var widthAtDragStart: CGFloat?
    @State private var hasPushedCursor = false

    var body: some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .onHover { inside in
                // Push and pop strictly in pairs, or the cursor stack drifts.
                if inside, !hasPushedCursor {
                    NSCursor.resizeLeftRight.push()
                    hasPushedCursor = true
                } else if !inside, hasPushedCursor {
                    NSCursor.pop()
                    hasPushedCursor = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = widthAtDragStart ?? store.sidebarWidth
                        widthAtDragStart = start
                        store.setSidebarWidth(start + value.translation.width)
                    }
                    .onEnded { _ in
                        widthAtDragStart = nil
                        store.commitSidebarWidth()
                    }
            )
            .accessibilityHidden(true)
    }
}
