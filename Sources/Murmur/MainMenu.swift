import AppKit

/// The standard Mac menu bar. Murmur used to ship only an Edit menu, which was
/// enough for text fields in an alert but leaves a real app looking unfinished
/// — no ⌘, for settings, no Window menu, no About.
///
/// Items with a nil target travel the responder chain and land on AppDelegate.
enum MainMenu {
    static func build() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(appMenu())
        menu.addItem(editMenu())
        menu.addItem(windowMenu())
        menu.addItem(helpMenu())
        return menu
    }

    private static func appMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: "Murmur")

        submenu.addItem(withTitle: "About Murmur",
                        action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        submenu.addItem(.separator())

        let settings = submenu.addItem(withTitle: "Settings…",
                                       action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]

        submenu.addItem(.separator())
        submenu.addItem(withTitle: "Hide Murmur",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = submenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        submenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")

        submenu.addItem(.separator())
        submenu.addItem(withTitle: "Quit Murmur",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.submenu = submenu
        return item
    }

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: "Edit")

        submenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = submenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        submenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        submenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        submenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        item.submenu = submenu
        return item
    }

    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: "Window")

        submenu.addItem(withTitle: "Murmur",
                        action: #selector(AppDelegate.showHistoryWindow(_:)), keyEquivalent: "0")
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "Minimize",
                        action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        submenu.addItem(withTitle: "Zoom",
                        action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "Bring All to Front",
                        action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        item.submenu = submenu
        NSApp.windowsMenu = submenu
        return item
    }

    private static func helpMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: "Help")
        submenu.addItem(withTitle: "How to Use Murmur",
                        action: #selector(AppDelegate.showHelp(_:)), keyEquivalent: "?")
        item.submenu = submenu
        NSApp.helpMenu = submenu
        return item
    }
}
