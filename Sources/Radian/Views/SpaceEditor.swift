import RadianCore
import SwiftUI

/// Sheet for renaming a space and choosing its icon, theme and profile.
struct SpaceEditor: View {
    @Environment(BrowserStore.self) private var store
    let spaceID: UUID

    private static let symbols = [
        "house.fill", "briefcase.fill", "bolt.fill", "star.fill", "heart.fill", "book.fill", "leaf.fill",
        "moon.fill", "flame.fill", "sparkles", "globe.americas.fill", "music.note", "gamecontroller.fill",
        "cart.fill", "graduationcap.fill", "chevron.left.forwardslash.chevron.right",
    ]

    var body: some View {
        if let space = store.state.space(withID: spaceID) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Edit Space")
                    .font(.headline)

                TextField("Name", text: binding(space.name) { $0.name = $1 })
                    .textFieldStyle(.roundedBorder)

                section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 9), spacing: 6) {
                        ForEach(SpaceEditor.symbols, id: \.self) { symbol in
                            choice(isSelected: space.icon == .symbol(symbol)) {
                                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                            } action: {
                                store.updateSpace(spaceID) { $0.icon = .symbol(symbol) }
                            }
                        }
                    }
                    HStack {
                        Text("Or an emoji")
                            .foregroundStyle(.secondary)
                        TextField("🙂", text: emojiBinding(space))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 52)
                    }
                    .font(.system(size: 12))
                }

                section("Theme") {
                    HStack(spacing: 8) {
                        ForEach(Array(SpaceTheme.presets.enumerated()), id: \.offset) { _, preset in
                            Button {
                                store.updateSpace(spaceID) { $0.theme = preset }
                            } label: {
                                Circle()
                                    .fill(preset.gradient)
                                    .frame(width: 26, height: 26)
                                    .overlay(
                                        Circle().strokeBorder(.primary.opacity(space.theme.colors == preset.colors ? 0.9 : 0.15), lineWidth: 2)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 14) {
                        ColorPicker("From", selection: colorBinding(space, stop: 0), supportsOpacity: false)
                        ColorPicker("To", selection: colorBinding(space, stop: 1), supportsOpacity: false)
                    }
                    .font(.system(size: 12))
                    HStack {
                        Text("Intensity")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Slider(value: binding(space.theme.intensity) { $0.theme.intensity = $1 }, in: 0.15...1)
                    }
                }

                section("Profile") {
                    HStack {
                        Picker("Profile", selection: profileBinding(space)) {
                            ForEach(store.state.profiles) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        }
                        .labelsHidden()
                        Button("New Profile") {
                            store.setProfile(store.newProfile(), forSpace: spaceID)
                        }
                    }
                    Text("Spaces on the same profile share logins and favorites.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Delete Space", role: .destructive) {
                        store.deleteSpace(spaceID)
                    }
                    .disabled(store.state.spaces.count < 2)
                    Spacer()
                    Button("Done") {
                        store.editingSpaceID = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
            .frame(width: 390)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func choice<Label: View>(
        isSelected: Bool,
        @ViewBuilder label: () -> Label,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    private func binding<Value>(_ value: Value, set: @escaping (inout Space, Value) -> Void) -> Binding<Value> {
        Binding(get: { value }, set: { newValue in store.updateSpace(spaceID) { set(&$0, newValue) } })
    }

    private func emojiBinding(_ space: Space) -> Binding<String> {
        Binding(
            get: {
                if case .emoji(let emoji) = space.icon { return emoji }
                return ""
            },
            set: { text in
                // Keep only the last character typed, so typing over an emoji replaces it.
                guard let last = text.last else { return }
                store.updateSpace(spaceID) { $0.icon = .emoji(String(last)) }
            }
        )
    }

    private func colorBinding(_ space: Space, stop: Int) -> Binding<Color> {
        Binding(
            get: { space.theme.gradientStops[min(stop, space.theme.gradientStops.count - 1)].color },
            set: { color in
                store.updateSpace(spaceID) { space in
                    var stops = Array(space.theme.gradientStops.prefix(2))
                    stops[stop] = RGBAColor(color)
                    space.theme.colors = stops
                }
            }
        )
    }

    private func profileBinding(_ space: Space) -> Binding<UUID> {
        Binding(get: { space.profileID }, set: { store.setProfile($0, forSpace: spaceID) })
    }
}
