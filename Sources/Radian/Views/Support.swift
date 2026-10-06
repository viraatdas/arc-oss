import AppKit
import RadianCore
import SwiftUI

// MARK: - Theme

extension RGBAColor {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    init(_ color: Color) {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        self.init(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent)
        )
    }
}

extension SpaceTheme {
    var gradient: LinearGradient {
        LinearGradient(colors: gradientStops.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// How opaque the gradient is over the window material.
    var tintOpacity: Double { 0.25 + 0.7 * intensity }

    /// Whether sidebar text should be light or dark to stay readable over this theme.
    func contentScheme(system: ColorScheme) -> ColorScheme {
        let base = system == .dark ? 0.03 : 0.9
        let blended = base * (1 - tintOpacity) + sidebarLuminance * tintOpacity
        return blended < 0.36 ? .dark : .light
    }
}

struct ThemeBackground: View {
    let theme: SpaceTheme

    var body: some View {
        ZStack {
            VisualEffect(material: .sidebar)
            theme.gradient.opacity(theme.tintOpacity)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

/// Makes a stretch of empty chrome behave like a title bar: drag to move, double-click to zoom.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

// MARK: - Small shared views

struct SpaceIconView: View {
    let icon: SpaceIcon
    var size: CGFloat = 14

    var body: some View {
        switch icon {
        case .emoji(let emoji):
            Text(emoji).font(.system(size: size))
        case .symbol(let name):
            Image(systemName: SpaceIconView.isKnownSymbol(name) ? name : "circle.fill")
                .font(.system(size: size * 0.9, weight: .semibold))
        }
    }

    /// Imported spaces can carry icon names that are not SF Symbols.
    static func isKnownSymbol(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}

struct FaviconView: View {
    @Environment(BrowserStore.self) private var store
    let url: URL?
    var size: CGFloat = 16

    var body: some View {
        if let image = store.favicons.image(for: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.82))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

/// A borderless icon button for the window chrome.
struct ChromeButton: View {
    let symbol: String
    var help: String = ""
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.primary.opacity(isHovering && isEnabled ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary.opacity(isEnabled ? 0.7 : 0.25))
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(ChromeButton.spokenLabel(for: help))
    }

    /// "Reload (⌘R)" reads better without the shortcut.
    static func spokenLabel(for help: String) -> String {
        help.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
            Text(toast.text).lineLimit(1)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }
}
