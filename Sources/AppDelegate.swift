import AppKit
import ServiceManagement

/// Flags for the test hooks. Real launches have none of these.
struct LaunchOptions {
    var action: String?
    var paths: [String] = []
    var mode: String?
    var pick: String?
    var select: Int?
    var output: String?

    static func parse(_ raw: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 0
        func value(_ offset: Int) -> String? {
            index + offset < raw.count ? raw[index + offset] : nil
        }
        while index < raw.count {
            let argument = raw[index]
            switch argument {
            case "--demo", "--simulate", "--hit", "--settings":
                options.action = String(argument.dropFirst(2))
                index += 1
            case "--unregister":
                options.action = "unregister"
                index += 1
            case "--settings-check":
                options.action = "settingscheck"
                index += 1
            case "--settings-shot":
                options.action = "settingsshot"
                options.output = value(1)
                index += options.output == nil ? 1 : 2
            case "--render":
                options.action = "render"
                options.output = value(1)
                index += options.output == nil ? 1 : 2
            case "--mode":
                options.mode = value(1)
                index += 2
            case "--pick":
                options.pick = value(1)
                index += 2
            case "--select":
                options.select = value(1).flatMap(Int.init)
                index += 2
            default:
                options.paths.append(argument)
                index += 1
            }
        }
        return options
    }

    var files: [URL] { paths.map { URL(fileURLWithPath: $0) } }
    var wheelMode: WheelMode {
        WheelMode.allCases.first { $0.title.lowercased() == (mode ?? "convert").lowercased() } ?? .convert
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = StateMonitor()
    private let wheel = WheelController()
    private var statusItem: NSStatusItem?

    private var interactive = false
    private var dragging = false
    private var modifiers: Set<ModifierKey> = []
    private var pendingMode: WheelMode?
    private var retries = 0
    /// Drag pasteboard generation seen while no drag was running.
    private var idleDragCount = NSPasteboard(name: .drag).changeCount
    /// Filled when the wheel is opened from the menu bar instead of a drag.
    private var fallbackFiles: [URL] = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makeStatusItem()
        wheel.onStatus = { text in
            // Errors always surface, even with notifications turned off.
            if Settings.shared.showsToast || !text.hasPrefix("Saved") {
                Toast.shared.show(text)
            }
        }

        let options = LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
        if let action = options.action {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.run(action: action, options: options)
            }
            return
        }

        startMonitoring()
        registerAtLoginIfNeeded()
        Log.write("launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    private func startMonitoring() {
        monitor.start(StateMonitor.Handlers(
            press: { [weak self] point in
                self?.handlePress(at: point)
            },
            release: { [weak self] point in
                self?.handleRelease(at: point)
            },
            move: { [weak self] point in
                self?.handleMove(to: point)
            },
            modifiers: { [weak self] flags, point in
                self?.handleModifiers(flags, at: point)
            }
        ))
    }

    // MARK: - Drag and modifier state machine

    private func handlePress(at point: NSPoint) {
        dragging = true
        pendingMode = nil
        retries = 0
        modifiers = StateMonitor.currentModifiers()
        Log.write("press at \(Int(point.x)),\(Int(point.y))")
    }

    private func handleRelease(at point: NSPoint) {
        dragging = false
        pendingMode = nil
        idleDragCount = NSPasteboard(name: .drag).changeCount
        guard wheel.isOpen else { return }
        wheel.updatePointer(point)
        wheel.applySelection()
    }

    private func handleMove(to point: NSPoint) {
        guard wheel.isOpen, !interactive else { return }
        wheel.updatePointer(point)
    }

    private func handleModifiers(_ flags: Set<ModifierKey>, at point: NSPoint) {
        let pressed = flags.subtracting(modifiers)
        modifiers = flags
        guard dragging, let key = preferred(pressed),
              let mode = Settings.shared.mode(for: key) else { return }

        if wheel.isOpen {
            wheel.switchMode(mode)
            return
        }
        openWheel(mode: mode, at: point)
    }

    private func openWheel(mode: WheelMode, at point: NSPoint) {
        let files = draggedOrFallback()
        guard !files.isEmpty else {
            // The drag pasteboard fills a beat after the button goes down.
            pendingMode = mode
            scheduleRetry()
            return
        }
        pendingMode = nil
        interactive = false
        wheel.open(files: files, mode: mode, at: point, interactive: false)
    }

    private func scheduleRetry() {
        guard retries < 60 else {
            Log.write("no files on the drag pasteboard")
            return
        }
        retries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard let pending = self.pendingMode, self.dragging, !self.wheel.isOpen else { return }
            let files = self.draggedOrFallback()
            guard !files.isEmpty else {
                self.scheduleRetry()
                return
            }
            self.pendingMode = nil
            self.interactive = false
            self.wheel.open(files: files, mode: pending, at: NSEvent.mouseLocation, interactive: false)
        }
    }

    private func draggedOrFallback() -> [URL] {
        let dragged = FileResolver.draggedFiles(idleChangeCount: idleDragCount)
        return dragged.isEmpty ? fallbackFiles : dragged
    }

    private func preferred(_ keys: Set<ModifierKey>) -> ModifierKey? {
        ModifierKey.allCases.first { keys.contains($0) }
    }

    // MARK: - Menu bar

    private func showWheelForSelection() {
        let files = FileResolver.finderSelection()
        guard !files.isEmpty else {
            Toast.shared.show("Select a file in Finder first")
            return
        }
        fallbackFiles = files
        interactive = true
        wheel.open(files: files, mode: .convert, at: NSEvent.mouseLocation, interactive: true)
    }

    // MARK: - Login item

    private var startsAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func registerAtLoginIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "didRegisterLogin") else { return }
        UserDefaults.standard.set(true, forKey: "didRegisterLogin")
        let status = SMAppService.mainApp.status
        Log.write("login item: status \(status.rawValue)")
        guard status == .notRegistered || status == .notFound else { return }
        do {
            try SMAppService.mainApp.register()
            Log.write("login item: registered")
        } catch {
            Log.write("login item: \(error.localizedDescription)")
        }
    }

    @objc private func menuToggleLogin() {
        do {
            if startsAtLogin {
                try SMAppService.mainApp.unregister()
                Log.write("login item: removed")
            } else {
                try SMAppService.mainApp.register()
                Log.write("login item: registered")
            }
        } catch {
            Log.write("login item: \(error.localizedDescription)")
            Toast.shared.show("Could not change the login item")
        }
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "circle.hexagongrid.fill",
                                accessibilityDescription: "Mandarina")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Mandarina"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show wheel for selection",
                                action: #selector(menuShowWheel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…",
                                action: #selector(menuOpenSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at login",
                               action: #selector(menuToggleLogin), keyEquivalent: "")
        login.state = startsAtLogin ? .on : .off
        menu.addItem(login)
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open log",
                                action: #selector(menuOpenLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Mandarina",
                                action: #selector(menuQuit), keyEquivalent: "q"))
        for entry in menu.items where entry.action != nil {
            entry.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func menuShowWheel() {
        showWheelForSelection()
    }

    @objc private func menuOpenSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func menuOpenLog() {
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // Keep the checkbox honest when macOS turns the login item off elsewhere.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(menuToggleLogin) {
            item.state = startsAtLogin ? .on : .off
        }
    }

    // MARK: - Test hooks

    private func run(action: String, options: LaunchOptions) {
        switch action {
        case "demo": runDemo(options)
        case "simulate": runSimulation(options)
        case "render": runRender(options)
        case "hit": runHitTest(options)
        case "settings":
            SettingsWindowController.shared.show()
            print("settings: open")
        case "unregister":
            do {
                try SMAppService.mainApp.unregister()
                print("unregistered")
            } catch {
                print("unregister failed: \(error.localizedDescription)")
            }
            exit(0)
        case "settingscheck":
            runSettingsCheck()
        case "settingsshot":
            SettingsWindowController.shared.snapshot(to: options.output ?? "/tmp/settings.png")
            print("settings: wrote \(options.output ?? "/tmp/settings.png")")
            NSApp.terminate(nil)
        default: NSApp.terminate(nil)
        }
    }

    private func runDemo(_ options: LaunchOptions) {
        interactive = true
        wheel.onStatus = { text in
            print("status: \(text)")
            Toast.shared.show(text)
        }
        wheel.open(files: options.files, mode: options.wheelMode,
                   at: NSEvent.mouseLocation, interactive: true)
        print("demo: \(options.files.count) file(s), open \(wheel.isOpen), items \(wheel.currentItemCount)")
    }

    private func runSimulation(_ options: LaunchOptions) {
        interactive = false
        wheel.onStatus = { text in
            print("status: \(text)")
            // Progress messages keep the hook alive; anything else is a result.
            if !text.hasPrefix("Converting") && !text.hasPrefix("Applying") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            }
        }
        wheel.open(files: options.files, mode: options.wheelMode,
                   at: NSPoint(x: 400, y: 400), interactive: false)
        print("simulate: mode \(options.wheelMode.title), items \(wheel.currentItemCount)")

        if let target = options.pick {
            var steps = 0
            while steps < 14 {
                guard let item = wheel.currentItem else { break }
                if item.id.lowercased() == target.lowercased()
                    || item.title.lowercased() == target.lowercased() { break }
                _ = wheel.handleKey(124)
                steps += 1
            }
            print("simulate: selected \(wheel.currentItem?.id ?? "none") after \(steps) steps")
        }

        wheel.applySelection(force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            print("simulate: timeout")
            NSApp.terminate(nil)
        }
    }

    /// Proves the pointer-to-wedge maths: every wedge centre must map back to
    /// its own index, and the hub must map to nothing.
    private func runHitTest(_ options: LaunchOptions) {
        let size = WheelController.size
        let view = WheelView(frame: NSRect(origin: .zero, size: size))
        let items = WheelCatalog.items(mode: options.wheelMode, files: options.files)
        view.items = items
        let center = NSPoint(x: size.width / 2, y: size.height / 2)
        let midRadius = (WheelView.Style.inner + WheelView.Style.outer) / 2
        let per = 2 * Double.pi / Double(max(1, items.count))
        var failures = 0
        for index in items.indices {
            let angle = Double.pi / 2 + Double(index) * per
            // Spell out the CGFloat conversions: cos(Double) and cos(CGFloat)
            // are both visible, and older Swift cannot pick between them.
            let point = NSPoint(x: center.x + CGFloat(cos(angle)) * midRadius,
                                y: center.y + CGFloat(sin(angle)) * midRadius)
            let got = view.index(at: point)
            let ok = got == index
            if !ok { failures += 1 }
            print("hit \(index) \(items[index].id): \(ok ? "ok" : "GOT \(got.map(String.init) ?? "nil")")")
        }
        let hub = view.index(at: center)
        if hub != nil { failures += 1 }
        print("hit centre: \(hub == nil ? "ok" : "unexpected \(hub!)")")
        let outside = view.index(at: NSPoint(x: center.x + WheelView.Style.outer + 40, y: center.y))
        if outside != nil { failures += 1 }
        print("hit outside: \(outside == nil ? "ok" : "unexpected \(outside!)")")
        print("hit: \(failures) failure(s), \(items.count) items")
        NSApp.terminate(nil)
    }

    /// Proves the key swap: assigning a key another wheel owns moves that wheel
    /// to the key the first one had, so the three never collide.
    private func runSettingsCheck() {
        let settings = Settings.shared
        settings.reset()
        func describe() -> String {
            WheelMode.allCases.map { "\($0.title)=\(settings.modifier(for: $0).name)" }.joined(separator: " ")
        }
        print("defaults: \(describe())")

        settings.setModifier(.command, for: .convert)
        print("convert=command -> \(describe())")
        let clash = WheelMode.allCases.filter { settings.modifier(for: $0) == .command }.count
        print("keys mapped to command: \(clash)")

        settings.setModifier(.option, for: .actions)
        print("actions=option -> \(describe())")

        settings.setScale(.large)
        print("scale: \(settings.scale.title) \(WheelView.Style.outer)")
        settings.setScale(.normal)
        print("scale back: \(settings.scale.title) \(WheelView.Style.outer)")

        settings.reset()
        print("reset: \(describe())")
        exit(clash == 1 ? 0 : 1)
    }

    private func runRender(_ options: LaunchOptions) {
        let size = WheelController.size
        let view = WheelView(frame: NSRect(origin: .zero, size: size))
        let items = WheelCatalog.items(mode: options.wheelMode, files: options.files)
        view.items = items
        view.mode = options.wheelMode
        view.selectedIndex = min(max(0, options.select ?? 0), max(0, items.count - 1))
        view.title = options.files.count == 1
            ? (options.files.first?.lastPathComponent ?? "")
            : "\(options.files.count) files"
        view.subtitle = items.isEmpty
            ? options.wheelMode.emptyMessage
            : "\(options.wheelMode.title) · \(items.count)"

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("render: no bitmap")
            NSApp.terminate(nil)
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        // Composite over a desktop-like backdrop with Core Graphics, so the
        // translucent plate is judged against something, not white paper.
        let scale: CGFloat = 2
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            print("render: no context")
            NSApp.terminate(nil)
            return
        }
        let colors = [
            NSColor(srgbRed: 0.15, green: 0.18, blue: 0.27, alpha: 1).cgColor,
            NSColor(srgbRed: 0.34, green: 0.25, blue: 0.30, alpha: 1).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: height),
                                       end: CGPoint(x: width, y: 0),
                                       options: [])
        }
        if let cgImage = rep.cgImage {
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let combined = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: combined).representation(using: .png, properties: [:]) else {
            print("render: encode failed")
            NSApp.terminate(nil)
            return
        }
        let destination = options.output ?? "/tmp/wheel.png"
        do {
            try png.write(to: URL(fileURLWithPath: destination))
            print("render: wrote \(destination), \(items.count) items, \(options.wheelMode.title)")
        } catch {
            print("render: \(error.localizedDescription)")
        }
        NSApp.terminate(nil)
    }
}
