import AppKit

class StatusBarController {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let statusMenuItem: NSMenuItem

    var onSetAPIKey: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        let apiKeyItem = NSMenuItem(title: "Set API Key...", action: #selector(apiKeyClicked), keyEquivalent: "k")
        apiKeyItem.target = self
        menu.addItem(apiKeyItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit MyWhisper", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        setIdle()
    }

    func setIdle() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "MyWhisper")
            button.image?.isTemplate = true
        }
    }

    func setRecording() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
        }
    }

    func setTranscribing() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "ellipsis.circle.fill", accessibilityDescription: "Transcribing")
            button.image?.isTemplate = false
            button.contentTintColor = .systemYellow
        }
    }

    func updateStatus(_ text: String) {
        statusMenuItem.title = text
    }

    @objc private func apiKeyClicked() {
        onSetAPIKey?()
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}
