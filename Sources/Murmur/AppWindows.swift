import AppKit
import SwiftUI

/// Owns the app's real windows. Murmur is an AppKit app with a SwiftUI
/// interior, so each window is a plain NSWindow wrapping an NSHostingView —
/// which also keeps the status-bar path working when no window is open.
final class AppWindows {
    static let shared = AppWindows()

    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?

    private init() {}

    func showHistory() {
        if historyWindow == nil {
            historyWindow = makeWindow(
                title: "Murmur",
                size: NSSize(width: 720, height: 520),
                autosave: "MurmurHistoryWindow",
                content: HistoryView(state: .shared)
            )
        }
        present(historyWindow)
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = makeWindow(
                title: "Settings",
                size: NSSize(width: 700, height: 480),
                autosave: "MurmurSettingsWindow",
                content: SettingsView(state: .shared)
            )
            // Settings windows don't belong in the Window menu or in cycling.
            window.isExcludedFromWindowsMenu = true
            settingsWindow = window
        }
        present(settingsWindow)
    }

    // MARK: - Plumbing

    private func makeWindow<Content: View>(
        title: String,
        size: NSSize,
        autosave: String,
        content: Content
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            // No .fullSizeContentView: the titlebar is opaque, so extending the
            // content under it just hides the top of the view.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = false
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName(autosave)
        return window
    }

    /// Brings a window forward, activating the app first — the status-bar menu
    /// and the hotkey both fire while another app owns focus.
    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
