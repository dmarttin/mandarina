import AppKit
import ServiceManagement

/// The settings pane. Everything here is live: the wheel reads the same
/// Settings object on the next drag, so a change applies without relaunching.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var popups: [WheelMode: NSPopUpButton] = [:]
    private var scaleControl: NSSegmentedControl!
    private var toastCheck: NSButton!
    private var revealCheck: NSButton!
    private var loginCheck: NSButton!

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Mandarina Settings"
        window.isReleasedWhenClosed = false
        // Come to whatever Space the user is on, fullscreen apps included.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show() {
        Log.write("settings: show")
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // An accessory app can be refused activation; the pane still has to show.
        window?.orderFrontRegardless()
        if let window {
            Log.write("settings: frame \(window.frame) visible \(window.isVisible) screen \(NSScreen.main?.frame ?? .zero) active \(NSApp.isActive)")
        }
    }

    /// Renders the pane to a PNG, for reviewing the layout without a screen.
    func snapshot(to path: String) {
        refresh()
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)

        let scale: CGFloat = 2
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let image = rep.cgImage {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let combined = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: combined).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Layout

    private func build() {
        guard let window, let content = window.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26)
        ])

        var keyRows: [NSView] = []
        for mode in WheelMode.allCases {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: ModifierKey.allCases.map { "\($0.hint)  \($0.name)" })
            popup.target = self
            popup.action = #selector(modifierChanged(_:))
            popup.tag = mode.rawValue
            popup.font = .systemFont(ofSize: 13)
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 156).isActive = true
            popups[mode] = popup
            keyRows.append(row(title: mode.title, control: popup))
        }
        add(section("Wheel keys", rows: keyRows), to: stack)

        scaleControl = NSSegmentedControl(labels: WheelScale.allCases.map(\.title),
                                          trackingMode: .selectOne,
                                          target: self,
                                          action: #selector(scaleChanged(_:)))
        add(section("Wheel size", rows: [row(title: "Size", control: scaleControl)]), to: stack)

        toastCheck = NSButton(checkboxWithTitle: "Notify when a conversion finishes",
                              target: self, action: #selector(toastToggled(_:)))
        revealCheck = NSButton(checkboxWithTitle: "Reveal the result in Finder",
                               target: self, action: #selector(revealToggled(_:)))
        add(section("After a conversion", rows: [toastCheck, revealCheck]), to: stack)

        loginCheck = NSButton(checkboxWithTitle: "Start at login",
                              target: self, action: #selector(loginToggled(_:)))
        add(section("General", rows: [loginCheck]), to: stack)
        add(section("Dependencies", rows: dependencyRows()), to: stack)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        let resetRow = NSStackView(views: [spacer, reset])
        resetRow.orientation = .horizontal
        resetRow.spacing = 12
        add(resetRow, to: stack)

        stack.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 520, height: stack.fittingSize.height + 52))
    }

    /// Adds a section and makes it as wide as the pane, so rows can push their
    /// controls to the right edge instead of hugging their own width.
    private func add(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func section(_ title: String, rows: [NSView]) -> NSView {
        let header = NSTextField(labelWithString: title.uppercased())
        header.font = .systemFont(ofSize: 10.5, weight: .semibold)
        header.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [header] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.setCustomSpacing(11, after: header)
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func row(title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        return row
    }

    // MARK: - State

    private func refresh() {
        for mode in WheelMode.allCases {
            let current = Settings.shared.modifier(for: mode)
            let index = ModifierKey.allCases.firstIndex(of: current) ?? 0
            popups[mode]?.selectItem(at: index)
        }
        scaleControl.selectedSegment = WheelScale.allCases.firstIndex(of: Settings.shared.scale) ?? 1
        toastCheck.state = Settings.shared.showsToast ? .on : .off
        revealCheck.state = Settings.shared.revealsAfterConvert ? .on : .off
        loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func modifierChanged(_ sender: NSPopUpButton) {
        guard let mode = WheelMode(rawValue: sender.tag) else { return }
        let index = min(max(0, sender.indexOfSelectedItem), ModifierKey.allCases.count - 1)
        Settings.shared.setModifier(ModifierKey.allCases[index], for: mode)
        // A key that another wheel owned moves to that wheel; show the result.
        refresh()
    }

    @objc private func scaleChanged(_ sender: NSSegmentedControl) {
        let index = min(max(0, sender.selectedSegment), WheelScale.allCases.count - 1)
        Settings.shared.setScale(WheelScale.allCases[index])
    }

    @objc private func toastToggled(_ sender: NSButton) {
        Settings.shared.setShowsToast(sender.state == .on)
    }

    @objc private func revealToggled(_ sender: NSButton) {
        Settings.shared.setRevealsAfterConvert(sender.state == .on)
    }

    // MARK: - Dependencies

    private func dependencyRows() -> [NSView] {
        Toolchain.status.map { status in
            let name = NSTextField(labelWithString: status.name)
            name.font = .systemFont(ofSize: 13)
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let detail: NSTextField
            if status.ready {
                detail = NSTextField(labelWithString: "Ready")
                detail.font = .systemFont(ofSize: 12)
                detail.textColor = .secondaryLabelColor
            } else {
                detail = NSTextField(labelWithString: status.install)
                detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                detail.textColor = .systemOrange
            }
            detail.setContentHuggingPriority(.defaultHigh, for: .horizontal)

            var views: [NSView] = [name, detail]
            if !status.ready {
                let copy = NSButton(title: "Copy", target: self, action: #selector(copyInstall(_:)))
                copy.bezelStyle = .inline
                copy.controlSize = .small
                copy.identifier = NSUserInterfaceItemIdentifier(status.install)
                views.append(copy)
            }

            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
            return row
        }
    }

    @objc private func copyInstall(_ sender: NSButton) {
        guard let command = sender.identifier?.rawValue else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        sender.title = "Copied"
    }

    // MARK: - Actions

    @objc private func resetDefaults() {
        Settings.shared.reset()
        refresh()
    }

    @objc private func loginToggled(_ sender: NSButton) {
        UserDefaults.standard.set(true, forKey: "didRegisterLogin")
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.write("login item: \(sender.state == .on ? "registered" : "removed") from settings")
        } catch {
            Log.write("login item: \(error.localizedDescription)")
        }
        refresh()
    }
}
