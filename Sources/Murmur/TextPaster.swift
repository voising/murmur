import AppKit
import CoreGraphics

enum TextPaster {
    private static let returnAfterPasteKey = "MurmurReturnAfterPaste"

    /// When on, a Return is sent after the paste — e.g. to submit a chat message.
    static var pressReturnAfterPaste: Bool {
        get { UserDefaults.standard.bool(forKey: returnAfterPasteKey) }
        set { UserDefaults.standard.set(newValue, forKey: returnAfterPasteKey) }
    }

    static func paste(text: String) {
        let pasteboard = NSPasteboard.general

        // Save current pasteboard contents
        let previousContents = pasteboard.pasteboardItems?.compactMap { item -> (String, Data)? in
            guard let type = item.types.first,
                  let data = item.data(forType: type) else { return nil }
            return (type.rawValue, data)
        }

        // Set transcribed text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        simulatePaste()

        let sendReturn = pressReturnAfterPaste

        // Restore previous pasteboard after a short delay. Press Return first
        // (if enabled) so it lands while the transcription is still focused.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if sendReturn {
                simulateReturn()
            }
            if let contents = previousContents, !contents.isEmpty {
                pasteboard.clearContents()
                for (typeRaw, data) in contents {
                    let type = NSPasteboard.PasteboardType(typeRaw)
                    pasteboard.setData(data, forType: type)
                }
            }
        }
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code for 'v' is 9
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func simulateReturn() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code for Return is 36
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
