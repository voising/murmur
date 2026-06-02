import AppKit
import ServiceManagement
import QuartzCore
import os

private let statusLog = Logger(subsystem: "com.railssquad.murmur", category: "statusbar")

class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusMenuItem: NSMenuItem
    private var history: [String] = []

    var onSetAPIKey: (() -> Void)?
    var onQuit: (() -> Void)?
    var onShowHelp: (() -> Void)?
    var onHistorySelect: ((String) -> Void)?
    var onHistoryClear: (() -> Void)?
    var onSetMouseTrigger: (() -> Void)?
    var onClearMouseTrigger: (() -> Void)?

    private var inputDevices: [AudioInputDevice] = []

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

    func setHistory(_ items: [String]) {
        history = items
        rebuildMenu()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        let header = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if history.isEmpty {
            let empty = NSMenuItem(title: "  No transcriptions yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, text) in history.enumerated() {
                let preview = text.prefix(60)
                let suffix = text.count > 60 ? "…" : ""
                let item = NSMenuItem(
                    title: "  \(preview)\(suffix)",
                    action: #selector(historyItemClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = index
                item.toolTip = text
                menu.addItem(item)
            }
            let clear = NSMenuItem(title: "  Clear History", action: #selector(clearHistoryClicked), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }

        menu.addItem(.separator())

        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micItem.submenu = buildMicrophoneSubmenu()
        menu.addItem(micItem)

        let mouseItem = NSMenuItem(title: "Mouse Trigger", action: nil, keyEquivalent: "")
        mouseItem.submenu = buildMouseTriggerSubmenu()
        menu.addItem(mouseItem)

        let returnAfter = NSMenuItem(title: "Add Enter at End", action: #selector(toggleReturnAfterPaste), keyEquivalent: "")
        returnAfter.target = self
        returnAfter.state = TextPaster.pressReturnAfterPaste ? .on : .off
        menu.addItem(returnAfter)

        let launch = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        if #available(macOS 13.0, *) {
            launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            launch.isHidden = true
        }
        menu.addItem(launch)

        let apiKey = NSMenuItem(title: "Set API Key…", action: #selector(apiKeyClicked), keyEquivalent: "k")
        apiKey.target = self
        menu.addItem(apiKey)

        let help = NSMenuItem(title: "How to Use", action: #selector(helpClicked), keyEquivalent: "")
        help.target = self
        menu.addItem(help)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Murmur", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func buildMicrophoneSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        inputDevices = AudioDeviceManager.listInputDevices()
        let selectedUID = AudioDeviceManager.selectedUID

        let auto = NSMenuItem(title: "System Default", action: #selector(microphoneSelected(_:)), keyEquivalent: "")
        auto.target = self
        auto.tag = -1
        auto.state = (selectedUID == nil) ? .on : .off
        submenu.addItem(auto)

        if !inputDevices.isEmpty {
            submenu.addItem(.separator())
            for (index, device) in inputDevices.enumerated() {
                let item = NSMenuItem(title: device.name, action: #selector(microphoneSelected(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.state = (device.uid == selectedUID) ? .on : .off
                submenu.addItem(item)
            }
        }

        if let pinnedUID = selectedUID, !inputDevices.contains(where: { $0.uid == pinnedUID }) {
            submenu.addItem(.separator())
            let missing = NSMenuItem(title: "Pinned device not connected", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            submenu.addItem(missing)
        }

        return submenu
    }

    private func buildMouseTriggerSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if let button = KeyMonitor.triggerMouseButton {
            let current = NSMenuItem(title: "Bound to button \(button)", action: nil, keyEquivalent: "")
            current.isEnabled = false
            submenu.addItem(current)
            submenu.addItem(.separator())

            let rebind = NSMenuItem(title: "Re-bind…", action: #selector(setMouseTriggerClicked), keyEquivalent: "")
            rebind.target = self
            submenu.addItem(rebind)

            let clear = NSMenuItem(title: "Clear", action: #selector(clearMouseTriggerClicked), keyEquivalent: "")
            clear.target = self
            submenu.addItem(clear)
        } else {
            let none = NSMenuItem(title: "Not set", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
            submenu.addItem(.separator())

            let set = NSMenuItem(title: "Set Mouse Button…", action: #selector(setMouseTriggerClicked), keyEquivalent: "")
            set.target = self
            submenu.addItem(set)
        }

        return submenu
    }

    /// Rebuild the menu to reflect a changed mouse-trigger binding.
    func refreshMenu() {
        rebuildMenu()
    }

    // MARK: - Actions

    @objc private func setMouseTriggerClicked() { onSetMouseTrigger?() }
    @objc private func clearMouseTriggerClicked() { onClearMouseTrigger?() }

    @objc private func microphoneSelected(_ sender: NSMenuItem) {
        if sender.tag == -1 {
            AudioDeviceManager.selectedUID = nil
        } else if inputDevices.indices.contains(sender.tag) {
            AudioDeviceManager.selectedUID = inputDevices[sender.tag].uid
        }
        rebuildMenu()
    }


    @objc private func historyItemClicked(_ sender: NSMenuItem) {
        let index = sender.tag
        guard history.indices.contains(index) else { return }
        onHistorySelect?(history[index])
    }

    @objc private func clearHistoryClicked() {
        onHistoryClear?()
    }

    @objc private func toggleReturnAfterPaste() {
        TextPaster.pressReturnAfterPaste.toggle()
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Toast.show("Couldn't update login item: \(error.localizedDescription)", kind: .error)
        }
        rebuildMenu()
    }

    @objc private func apiKeyClicked() { onSetAPIKey?() }
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
