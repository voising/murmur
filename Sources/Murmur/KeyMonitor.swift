import AppKit
import CoreGraphics

class KeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Fired once per click of the bound mouse button (toggle semantics).
    var onMouseToggle: (() -> Void)?
    var onStatusChange: ((String) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightOptionDown = false
    private var retryTimer: Timer?

    // Learn mode: capture the next non-standard mouse button and bind it.
    private var learning = false
    private var learnCompletion: ((Int) -> Void)?
    private var pendingLearnUpButton: Int?

    private static let mouseButtonKey = "MurmurMouseTriggerButton"

    /// Persisted CGEvent button number bound as the push-to-talk trigger,
    /// or nil if none. Left (0) and right (1) can't be bound — they don't
    /// arrive as `otherMouse` events.
    static var triggerMouseButton: Int? {
        get { UserDefaults.standard.object(forKey: mouseButtonKey) as? Int }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: mouseButtonKey)
            } else {
                UserDefaults.standard.removeObject(forKey: mouseButtonKey)
            }
        }
    }

    /// Begin capturing the next mouse-button press as the trigger. The tap
    /// callback runs on the main run loop, so this is touched on one thread.
    func startLearningMouseButton(completion: @escaping (Int) -> Void) {
        learnCompletion = completion
        learning = true
    }

    func cancelLearningMouseButton() {
        learning = false
        learnCompletion = nil
    }

    func start() {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)

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

        if type == .otherMouseDown || type == .otherMouseUp {
            return handleMouseEvent(type: type, event: event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passRetained(event)
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

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

    private func handleMouseEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))

        // Learn mode: bind on the next button-down, then swallow its up so the
        // press doesn't double as a normal click.
        if learning, type == .otherMouseDown {
            KeyMonitor.triggerMouseButton = button
            pendingLearnUpButton = button
            learning = false
            let completion = learnCompletion
            learnCompletion = nil
            DispatchQueue.main.async { completion?(button) }
            return nil
        }
        if let pending = pendingLearnUpButton, type == .otherMouseUp, button == pending {
            pendingLearnUpButton = nil
            return nil
        }

        guard let bound = KeyMonitor.triggerMouseButton, button == bound else {
            return Unmanaged.passRetained(event)
        }

        // Toggle on the down event; swallow the matching up so the click can't
        // also fire the button's native action (e.g. Back navigation). Hold-to-
        // talk is unreliable on a mouse click — a normal click's down and up are
        // milliseconds apart — so the mouse trigger toggles instead.
        if type == .otherMouseDown {
            DispatchQueue.main.async { self.onMouseToggle?() }
        }
        return nil
    }

    private func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
