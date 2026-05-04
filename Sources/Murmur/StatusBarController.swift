import AppKit
import ServiceManagement
import QuartzCore

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
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Murmur")
            button.image?.isTemplate = true
            button.contentTintColor = nil
            button.alphaValue = 1
        }
    }

    func setRecording() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
            startPulse()
        }
    }

    func setTranscribing() {
        stopPulse()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Transcribing")
            button.image?.isTemplate = false
            button.contentTintColor = NSColor(calibratedRed: 0.40, green: 0.62, blue: 0.95, alpha: 1)
            startBreathing()
        }
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

    // MARK: - Actions

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

    private func startBreathing() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        button.layer?.removeAnimation(forKey: Self.pulseKey)
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.55
        anim.duration = 1.1
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(anim, forKey: Self.pulseKey)
    }

    private func stopPulse() {
        statusItem.button?.layer?.removeAnimation(forKey: Self.pulseKey)
        statusItem.button?.alphaValue = 1
    }
}
