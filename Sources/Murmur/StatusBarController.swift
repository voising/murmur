import AppKit
import QuartzCore
import os

private let statusLog = Logger(subsystem: "com.railssquad.murmur", category: "statusbar")

/// Menu-bar presence: recording indicator plus a short menu.
///
/// This used to be the app's entire interface, so every setting lived here in
/// a submenu. Configuration now belongs to the Settings window; what's left is
/// what you actually want one click away — current status, the last few
/// transcripts, and a way into the real windows.
class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusMenuItem: NSMenuItem
    private var history: [Transcription] = []

    var onQuit: (() -> Void)?
    var onShowHelp: (() -> Void)?
    var onHistorySelect: ((String) -> Void)?
    var onOpenHistory: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    /// How many transcripts the menu shows before deferring to the window.
    private static let menuHistoryLimit = 5

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenuItem = NSMenuItem(title: "Ready — hold right Option", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        super.init()

        statusItem.menu = menu
        menu.autoenablesItems = false
        rebuildMenu()
        setIdle()
    }

    // MARK: - Public API

    func setIdle() {
        stopPulse()
        guard let button = statusItem.button else {
            statusLog.error("setIdle: statusItem.button is nil")
            return
        }
        let img = NSImage(systemSymbolName: "mic", accessibilityDescription: "Murmur")
        button.image = img
        button.image?.isTemplate = true
        button.contentTintColor = nil
        button.alphaValue = 1
        statusLog.notice("setIdle: image=\(img == nil ? "NIL" : "mic", privacy: .public) len=\(self.statusItem.length, privacy: .public) visible=\(self.statusItem.isVisible, privacy: .public)")
    }

    func setRecording() {
        guard let button = statusItem.button else {
            statusLog.error("setRecording: statusItem.button is nil")
            return
        }
        let img = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
        button.image = img
        button.image?.isTemplate = false
        button.contentTintColor = .systemRed
        startPulse()
        statusLog.notice("setRecording: image=\(img == nil ? "NIL" : "mic.fill", privacy: .public) len=\(self.statusItem.length, privacy: .public) visible=\(self.statusItem.isVisible, privacy: .public)")
    }

    func setTranscribing() {
        stopPulse()
        startSpinning()
        statusLog.notice("setTranscribing: frames=\(Self.spinFrames.count, privacy: .public) len=\(self.statusItem.length, privacy: .public) visible=\(self.statusItem.isVisible, privacy: .public)")
    }

    func updateStatus(_ text: String) {
        statusMenuItem.title = text
    }

    func setHistory(_ items: [Transcription]) {
        history = items
        rebuildMenu()
    }

    /// Rebuild the menu to reflect a changed binding made elsewhere.
    func refreshMenu() {
        rebuildMenu()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if history.isEmpty {
            let empty = NSMenuItem(title: "  No transcriptions yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, entry) in history.prefix(Self.menuHistoryLimit).enumerated() {
                let preview = entry.text.prefix(60)
                let suffix = entry.text.count > 60 ? "…" : ""
                let item = NSMenuItem(
                    title: "  \(preview)\(suffix)",
                    action: #selector(historyItemClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = index
                item.toolTip = entry.text
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Murmur", action: #selector(openHistoryClicked), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsClicked), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let help = NSMenuItem(title: "How to Use", action: #selector(helpClicked), keyEquivalent: "")
        help.target = self
        menu.addItem(help)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Murmur", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func historyItemClicked(_ sender: NSMenuItem) {
        let index = sender.tag
        guard history.indices.contains(index) else { return }
        onHistorySelect?(history[index].text)
    }

    @objc private func openHistoryClicked() { onOpenHistory?() }
    @objc private func openSettingsClicked() { onOpenSettings?() }
    @objc private func helpClicked() { onShowHelp?() }
    @objc private func quitClicked() { onQuit?() }

    // MARK: - Pulse

    private static let pulseKey = "murmur.pulse"

    private func startPulse() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        button.layer?.removeAnimation(forKey: Self.pulseKey)
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.35
        anim.duration = 0.7
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(anim, forKey: Self.pulseKey)
    }

    // The status-bar button draws its symbol via the cell, not into its
    // backing layer, so a CALayer transform can't spin the icon. Instead we
    // cycle through pre-rendered rotated frames of the symbol.
    private static let spinFrames: [NSImage] = makeSpinnerFrames()
    private var spinTimer: Timer?
    private var spinIndex = 0

    private static func makeSpinnerFrames(count: Int = 12, pointSize: CGFloat = 15) -> [NSImage] {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let base = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                 accessibilityDescription: "Transcribing")?
            .withSymbolConfiguration(config) else { return [] }
        let size = base.size
        return (0..<count).map { i in
            let angle = -CGFloat(i) / CGFloat(count) * 2 * .pi   // clockwise
            let frame = NSImage(size: size)
            frame.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.translateBy(x: size.width / 2, y: size.height / 2)
                ctx.rotate(by: angle)
                ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
            }
            base.draw(in: NSRect(origin: .zero, size: size))
            frame.unlockFocus()
            frame.isTemplate = true   // adapts to menu-bar (black/white)
            return frame
        }
    }

    private func startSpinning() {
        guard let button = statusItem.button, !Self.spinFrames.isEmpty else {
            statusLog.error("startSpinning: button=\(self.statusItem.button == nil ? "nil" : "ok", privacy: .public) frames=\(Self.spinFrames.count, privacy: .public)")
            return
        }
        spinIndex = 0
        // Drop the red tint left over from recording — a tint colour overrides
        // template rendering, which is what makes the icon invisible in dark mode.
        button.contentTintColor = nil
        button.alphaValue = 1
        button.image = Self.spinFrames[0]
        spinTimer?.invalidate()
        spinTimer = Timer.scheduledTimer(withTimeInterval: 0.13, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            self.spinIndex = (self.spinIndex + 1) % Self.spinFrames.count
            button.image = Self.spinFrames[self.spinIndex]
        }
    }

    private func stopPulse() {
        spinTimer?.invalidate()
        spinTimer = nil
        statusItem.button?.layer?.removeAnimation(forKey: Self.pulseKey)
        statusItem.button?.alphaValue = 1
    }
}
