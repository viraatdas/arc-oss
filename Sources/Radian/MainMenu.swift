import AppKit

/// The menu bar. Built in code because the app has no nib; it is also where every keyboard
/// shortcut is defined.
@MainActor
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }

        /// An item handled by the app delegate.
        func item(
            _ title: String,
            _ action: Selector,
            _ key: String = "",
            _ modifiers: NSEvent.ModifierFlags = .command,
            tag: Int = 0
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            item.tag = tag
            return item
        }

        /// An item sent down the responder chain, so it reaches whichever view has focus.
        func system(
            _ title: String,
            _ action: Selector,
            _ key: String = "",
            _ modifiers: NSEvent.ModifierFlags = .command
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }

        func arrow(_ key: Int) -> String {
            String(UnicodeScalar(UInt16(key)).map(Character.init) ?? " ")
        }

        let separator = { NSMenuItem.separator() }

        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu

        _ = menu("Radian", [
            item("About Radian", #selector(AppDelegate.showAbout(_:))),
            separator(),
            item("Import from Arc…", #selector(AppDelegate.importFromArc(_:))),
            separator(),
            services,
            separator(),
            system("Hide Radian", #selector(NSApplication.hide(_:)), "h"),
            system("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            system("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            separator(),
            system("Quit Radian", #selector(NSApplication.terminate(_:)), "q"),
        ])

        _ = menu("File", [
            item("New Tab", #selector(AppDelegate.newTab(_:)), "t"),
            item("New Folder", #selector(AppDelegate.newFolder(_:)), "n", [.command, .option]),
            item("New Space", #selector(AppDelegate.newSpace(_:)), "n", [.command, .control]),
            item("Open Location…", #selector(AppDelegate.openLocation(_:)), "l"),
            separator(),
            item("Close Tab", #selector(AppDelegate.closeTab(_:)), "w"),
            system("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            item("Reopen Closed Tab", #selector(AppDelegate.reopenClosedTab(_:)), "t", [.command, .shift]),
            separator(),
            item("Print…", #selector(AppDelegate.printPage(_:)), "p"),
        ])

        _ = menu("Edit", [
            system("Undo", Selector(("undo:")), "z"),
            system("Redo", Selector(("redo:")), "z", [.command, .shift]),
            separator(),
            system("Cut", #selector(NSText.cut(_:)), "x"),
            system("Copy", #selector(NSText.copy(_:)), "c"),
            system("Paste", #selector(NSText.paste(_:)), "v"),
            system("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            system("Select All", #selector(NSText.selectAll(_:)), "a"),
            separator(),
            item("Find…", #selector(AppDelegate.findInPage(_:)), "f"),
            item("Copy Link", #selector(AppDelegate.copyLink(_:)), "c", [.command, .shift]),
        ])

        _ = menu("View", [
            item("Toggle Sidebar", #selector(AppDelegate.toggleSidebar(_:)), "s"),
            item("Toggle Split View", #selector(AppDelegate.toggleSplit(_:)), "=", [.control, .shift]),
            separator(),
            item("Reload Page", #selector(AppDelegate.reloadPage(_:)), "r"),
            item("Stop", #selector(AppDelegate.stopLoading(_:)), "."),
            separator(),
            item("Actual Size", #selector(AppDelegate.actualSize(_:)), "0"),
            item("Zoom In", #selector(AppDelegate.zoomIn(_:)), "="),
            item("Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-"),
            separator(),
            system("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        var tabItems = [
            item("Back", #selector(AppDelegate.goBack(_:)), "["),
            item("Forward", #selector(AppDelegate.goForward(_:)), "]"),
            separator(),
            item("Pin or Unpin Tab", #selector(AppDelegate.togglePin(_:)), "d"),
            item("Add to Favorites", #selector(AppDelegate.addToFavorites(_:)), "d", [.command, .shift]),
            separator(),
            item("Next Tab", #selector(AppDelegate.nextTab(_:)), arrow(NSDownArrowFunctionKey), [.command, .option]),
            item("Previous Tab", #selector(AppDelegate.previousTab(_:)), arrow(NSUpArrowFunctionKey), [.command, .option]),
            // The same two commands on the shortcut other browsers use.
            alternate(item("Next Tab", #selector(AppDelegate.nextTab(_:)), "\t", [.control])),
            alternate(item("Previous Tab", #selector(AppDelegate.previousTab(_:)), "\t", [.control, .shift])),
            separator(),
            item("Archive", #selector(AppDelegate.showArchive(_:)), "a", [.command, .shift]),
            separator(),
        ]
        tabItems += (0..<9).map { position in
            item("Tab \(position + 1)", #selector(AppDelegate.selectTabByPosition(_:)), "\(position + 1)", tag: position)
        }
        _ = menu("Tabs", tabItems)

        var spaceItems = [
            item("Edit Space…", #selector(AppDelegate.editSpace(_:))),
            separator(),
            item("Next Space", #selector(AppDelegate.nextSpace(_:)), arrow(NSRightArrowFunctionKey), [.command, .option]),
            item("Previous Space", #selector(AppDelegate.previousSpace(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option]),
            separator(),
        ]
        spaceItems += (0..<9).map { position in
            item(
                "Space \(position + 1)", #selector(AppDelegate.selectSpaceByPosition(_:)), "\(position + 1)",
                [.control], tag: position
            )
        }
        _ = menu("Spaces", spaceItems)

        let window = menu("Window", [
            system("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            system("Zoom", #selector(NSWindow.performZoom(_:))),
            separator(),
            system("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window

        return main
    }

    /// Hidden from the menu but still live as a keyboard shortcut.
    private static func alternate(_ item: NSMenuItem) -> NSMenuItem {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }
}
