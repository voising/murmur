import AppKit
import CoreGraphics

class KeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onStatusChange: ((String) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightOptionDown = false
    private var retryTimer: Timer?

    func start() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            onStatusChange?("Grant Accessibility permission, then restart")
            promptAccessibility()
            startRetrying()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        onStatusChange?("Ready — hold right Option to record")
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func startRetrying() {
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if AXIsProcessTrusted() {
                self.retryTimer?.invalidate()
                self.retryTimer = nil
                self.start()
            }
        }
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passRetained(event)
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let rawFlags = event.flags.rawValue

        // Debug: log every flagsChanged event
        print("[KeyMonitor] keycode=\(keycode) flags=0x\(String(rawFlags, radix: 16))")

        // Right Option key = keycode 61
        if keycode == 61 {
            let optionPressed = flags.contains(.maskAlternate)

            if optionPressed && !rightOptionDown {
                rightOptionDown = true
                DispatchQueue.main.async { self.onPress?() }
                return nil
            } else if !optionPressed && rightOptionDown {
                rightOptionDown = false
                DispatchQueue.main.async { self.onRelease?() }
                return nil
            }
        }

        return Unmanaged.passRetained(event)
    }

    private func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
