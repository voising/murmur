import AppKit

enum ToastKind {
    case info, success, error

    var accent: NSColor {
        switch self {
        case .info:    return NSColor(calibratedRed: 0.40, green: 0.62, blue: 0.95, alpha: 1)
        case .success: return NSColor(calibratedRed: 0.35, green: 0.80, blue: 0.55, alpha: 1)
        case .error:   return NSColor(calibratedRed: 0.96, green: 0.40, blue: 0.40, alpha: 1)
        }
    }

    var symbol: String {
        switch self {
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error:   return "exclamationmark.triangle.fill"
        }
    }
}

enum Toast {
    nonisolated(unsafe) private static var window: NSPanel?
    nonisolated(unsafe) private static var dismissTimer: Timer?

    static func show(_ message: String, kind: ToastKind = .info, duration: TimeInterval = 2.5) {
        let present = {
            dismissTimer?.invalidate()
            window?.orderOut(nil)
            window = nil

            let panel = makePanel(message: message, kind: kind)
            window = panel
            panel.alphaValue = 0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }

            dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
                dismiss()
            }
        }

        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.async(execute: present)
        }
    }

    private static func dismiss() {
        guard let panel = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            if window === panel { window = nil }
        })
    }

    private static func makePanel(message: String, kind: ToastKind) -> NSPanel {
        let padding: CGFloat = 14
        let iconSize: CGFloat = 18
        let maxWidth: CGFloat = 360

        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textSize = (message as NSString).boundingRect(
            with: NSSize(width: maxWidth - padding * 2 - iconSize - 10, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).size

        let width = min(maxWidth, ceil(textSize.width) + padding * 2 + iconSize + 10)
        let height = max(44, ceil(textSize.height) + padding * 2)

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let frame = NSRect(
            x: screen.visibleFrame.maxX - width - 24,
            y: screen.visibleFrame.maxY - height - 24,
            width: width,
            height: height
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true

        let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        root.material = .hudWindow
        root.state = .active
        root.blendingMode = .behindWindow
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.cornerCurve = .continuous
        root.layer?.borderWidth = 0.5
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        root.layer?.masksToBounds = true

        let stripe = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: frame.height))
        stripe.wantsLayer = true
        stripe.layer?.backgroundColor = kind.accent.cgColor
        root.addSubview(stripe)

        let iconConfig = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
        let icon = NSImageView(frame: NSRect(
            x: padding,
            y: (height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        ))
        icon.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        icon.contentTintColor = kind.accent
        root.addSubview(icon)

        let labelX = padding + iconSize + 10
        let label = NSTextField(frame: NSRect(
            x: labelX,
            y: padding,
            width: width - labelX - padding,
            height: height - padding * 2
        ))
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.font = font
        label.textColor = NSColor.labelColor
        label.stringValue = message
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        root.addSubview(label)

        panel.contentView = root
        return panel
    }
}
