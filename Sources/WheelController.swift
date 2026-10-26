import AppKit

final class WheelPanel: NSPanel {
    var onKey: ((UInt16) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKey?(event.keyCode) == true { return }
        super.keyDown(with: event)
    }
}

/// Owns the wheel's lifetime and turns a highlighted target into work.
final class WheelController {
    static var size: NSSize {
        let scale = WheelView.Style.scale
        return NSSize(width: 470 * scale, height: 500 * scale)
    }

    private var panel: WheelPanel?
    private var view: WheelView?
    private var files: [URL] = []
    private var mode: WheelMode = .convert
    private var selected = 0
    private var hovered = false
    private(set) var isOpen = false

    var onStatus: ((String) -> Void)?
    /// Live progress for the one or two jobs slow enough to need it.
    var onProgress: ((String) -> Void)?

    var currentItem: WheelItem? {
        (panel?.contentView as? WheelView)?.selectedItem()
    }

    var currentItemCount: Int {
        (panel?.contentView as? WheelView)?.items.count ?? 0
    }

    // MARK: - Opening and closing

    func open(files: [URL], mode: WheelMode, at point: NSPoint, interactive: Bool) {
        guard !files.isEmpty else {
            Log.write("open: no files")
            return
        }
        self.files = files
        self.mode = mode
        self.selected = 0
        self.hovered = false

        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let view = panel.contentView as? WheelView else { return }

        panel.ignoresMouseEvents = !interactive
        view.items = WheelCatalog.items(mode: mode, files: files)
        view.selectedIndex = 0
        view.mode = mode
        view.title = displayTitle(files)
        view.subtitle = subtitle(for: mode, count: view.items.count)

        var origin = NSPoint(x: point.x - Self.size.width / 2,
                             y: point.y - Self.size.height / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - Self.size.width - 8)
            origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - Self.size.height - 8)
        }
        panel.setFrameOrigin(origin)

        isOpen = true
        if interactive {
            NSApp.activate(ignoringOtherApps: true)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.10
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        Log.write("open: mode \(mode.title), items \(view.items.count), files \(files.count), interactive \(interactive)")
    }

    func cancel() {
        guard isOpen else { return }
        isOpen = false
        panel?.orderOut(nil)
        Log.write("cancel")
    }

    func switchMode(_ newMode: WheelMode) {
        guard isOpen, newMode != mode else { return }
        guard let view = panel?.contentView as? WheelView else { return }
        mode = newMode
        selected = 0
        view.mode = newMode
        view.items = WheelCatalog.items(mode: newMode, files: files)
        view.selectedIndex = 0
        view.subtitle = subtitle(for: newMode, count: view.items.count)
        Log.write("switch: \(newMode.title), items \(view.items.count)")
    }

    // MARK: - Pointer and keyboard

    func updatePointer(_ point: NSPoint) {
        guard isOpen, let panel, let view = panel.contentView as? WheelView else { return }
        let inWindow = panel.convertPoint(fromScreen: point)
        let inView = view.convert(inWindow, from: nil)
        guard let index = view.index(at: inView) else { return }
        hovered = true
        if index != selected {
            selected = index
            view.selectedIndex = index
        }
    }

    func step(_ delta: Int) {
        guard isOpen, let view = panel?.contentView as? WheelView, !view.items.isEmpty else { return }
        selected = (selected + delta + view.items.count) % view.items.count
        view.selectedIndex = selected
        hovered = true
    }

    func handleKey(_ code: UInt16) -> Bool {
        switch code {
        case 53: // escape
            cancel()
            return true
        case 36, 76: // return, enter
            applySelection(force: true)
            return true
        case 123, 126: // left, up
            step(-1)
            return true
        case 124, 125: // right, down
            step(1)
            return true
        default:
            return false
        }
    }

    // MARK: - Applying

    /// `force` is for Enter and the test hooks: an explicit choice applies the
    /// highlighted item even if the pointer never left the hub.
    func applySelection(force: Bool = false) {
        guard isOpen, let view = panel?.contentView as? WheelView else { return }
        guard force || hovered else {
            Log.write("drop in the hub, cancelled")
            cancel()
            return
        }
        guard let item = view.selectedItem() else {
            cancel()
            return
        }
        let targets = files
        cancel()

        if item.kind == .action {
            perform(action: item.id, on: targets)
            return
        }
        guard let action = item.action else { return }

        let label = item.kind == .conversion
            ? "Converting to \(item.title)…"
            : "Applying \(item.title)…"
        onStatus?(label)
        Log.write("apply: \(item.id) on \(targets.count) file(s)")

        var lastPercent = -1
        let progress: (Double) -> Void = { fraction in
            let percent = Int((fraction * 100).rounded())
            guard percent > 0, percent < 100, percent != lastPercent else { return }
            lastPercent = percent
            DispatchQueue.main.async {
                self.onProgress?("\(label) \(percent)%")
            }
        }

        Engine.run(action, suffix: item.suffix, files: targets, progress: progress) { [weak self] ok, written, message in
            guard let self else { return }
            if ok {
                let names = written.map(\.lastPathComponent)
                let summary = names.count > 2
                    ? "Saved \(names.count) files"
                    : "Saved \(names.joined(separator: ", "))"
                self.onStatus?(summary)
                Log.write("apply: wrote \(names.joined(separator: ", "))")
                if Settings.shared.revealsAfterConvert {
                    NSWorkspace.shared.activateFileViewerSelecting(written)
                }
            } else {
                self.onStatus?(message)
                Log.write("apply: failed \(message)")
            }
        }
    }

    private func perform(action: String, on urls: [URL]) {
        Log.write("action: \(action) \(urls.count) file(s)")
        switch action {
        case "copy-path":
            let text = urls.map(\.path).joined(separator: "\n")
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            onStatus?("Path copied")

        case "copy-file":
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
            onStatus?("File copied")

        case "reveal":
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            onStatus?("Revealed in Finder")

        case "terminal":
            let directory = urls.first?.deletingLastPathComponent().path ?? NSHomeDirectory()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Terminal", directory]
            try? process.run()
            onStatus?("Terminal opened")

        case "airdrop":
            guard let service = NSSharingService(named: .sendViaAirDrop) else {
                onStatus?("AirDrop unavailable")
                return
            }
            service.perform(withItems: urls)
            onStatus?("AirDrop")

        case "zip":
            onStatus?("Compressing…")
            DispatchQueue.global(qos: .userInitiated).async {
                var produced: [URL] = []
                for url in urls {
                    let destination = url.deletingPathExtension()
                        .appendingPathExtension("zip")
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    process.arguments = ["-c", "-k", "--sequesterRsrc",
                                         "--keepParent", url.path, destination.path]
                    do {
                        try process.run()
                        process.waitUntilExit()
                        if process.terminationStatus == 0 {
                            produced.append(destination)
                        }
                    } catch {
                        Log.write("zip: \(error.localizedDescription)")
                    }
                }
                DispatchQueue.main.async {
                    self.onStatus?(produced.isEmpty ? "Compress failed" : "Saved \(produced.map(\.lastPathComponent).joined(separator: ", "))")
                }
            }

        default:
            onStatus?("Not implemented")
        }
    }

    // MARK: - Helpers

    private func makePanel() -> WheelPanel {
        let panel = WheelPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered,
                               defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.onKey = { [weak self] code in
            self?.handleKey(code) ?? false
        }
        let view = WheelView(frame: NSRect(origin: .zero, size: Self.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        return panel
    }

    private func displayTitle(_ urls: [URL]) -> String {
        guard let first = urls.first else { return "" }
        if urls.count == 1 {
            return first.lastPathComponent
        }
        return "\(urls.count) files"
    }

    private func subtitle(for mode: WheelMode, count: Int) -> String {
        if count == 0 { return WheelCatalog.emptyReason(mode: mode, files: files) }
        return "\(mode.title) · \(count)"
    }
}
