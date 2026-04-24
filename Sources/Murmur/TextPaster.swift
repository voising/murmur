import AppKit
import CoreGraphics

enum TextPaster {
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

        // Restore previous pasteboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
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
}
