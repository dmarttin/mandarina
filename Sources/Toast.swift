import AppKit

/// A small floating confirmation, so a conversion that finishes after the drop
/// still tells the user what it wrote.
final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var pendingHide: DispatchWorkItem?

    /// Keeps the panel alive while a long job reports progress. Without this,
    /// the confirmation would disappear before the conversion finished.
    func update(_ text: String) {
        guard let panel, let label else {
            show(text)
            return
        }
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 34
        let size = NSSize(width: max(120, width), height: 32)
        let anchor = NSPoint(x: panel.frame.midX, y: panel.frame.maxY + 24)
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height))
        label.stringValue = text
        label.frame = NSRect(x: 0, y: 6, width: size.width, height: 20)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        scheduleHide()
    }

    func show(_ text: String, near point: NSPoint? = nil) {
        Log.write("toast: \(text)")
        let anchor = point ?? NSEvent.mouseLocation
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let width = ceil((text as NSString).size(withAttributes: attributes).width) + 34
        let size = NSSize(width: max(120, width), height: 32)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: anchor.x - size.width / 2,
                                     y: anchor.y - 56))

        if let label {
            label.stringValue = text
            label.frame = NSRect(x: 0, y: 6, width: size.width, height: 20)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        scheduleHide()
    }

    private func scheduleHide() {
        pendingHide?.cancel()
        let hide = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                self?.panel?.animator().alphaValue = 0
            }, completionHandler: {
                self?.panel?.orderOut(nil)
            })
        }
        pendingHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: hide)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 32),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 32))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 0.94).cgColor
        container.layer?.cornerRadius = 16
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 6, width: 220, height: 20)
        label.autoresizingMask = [.width]
        container.addSubview(label)
        self.label = label

        panel.contentView = container
        return panel
    }
}
