import AppKit

/// The modifier keys the wheel can listen for.
enum ModifierKey: String, CaseIterable {
    case shift
    case command
    case control
    case option

    var name: String {
        switch self {
        case .shift: return "Shift"
        case .command: return "Command"
        case .control: return "Control"
        case .option: return "Option"
        }
    }

    var hint: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .command: return .maskCommand
        case .control: return .maskControl
        case .option: return .maskAlternate
        }
    }

    /// Left and right key codes, for the second read of the same state.
    var keyCodes: [CGKeyCode] {
        switch self {
        case .shift: return [56, 60]
        case .command: return [55, 54]
        case .control: return [59, 62]
        case .option: return [58, 61]
        }
    }
}

enum WheelScale: String, CaseIterable {
    case compact
    case normal
    case large

    var value: CGFloat {
        switch self {
        case .compact: return 0.85
        case .normal: return 1.0
        case .large: return 1.2
        }
    }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .normal: return "Normal"
        case .large: return "Large"
        }
    }
}

final class Settings {
    static let shared = Settings()
    static let changed = Notification.Name("app.mandarina.settingsChanged")

    private let defaults = UserDefaults.standard

    private enum Key {
        static let convertModifier = "modifier.convert"
        static let toolsModifier = "modifier.tools"
        static let actionsModifier = "modifier.actions"
        static let scale = "wheel.scale"
        static let toast = "behaviour.toast"
        static let reveal = "behaviour.reveal"
    }

    private init() {
        defaults.register(defaults: [
            Key.convertModifier: ModifierKey.shift.rawValue,
            Key.toolsModifier: ModifierKey.command.rawValue,
            Key.actionsModifier: ModifierKey.control.rawValue,
            Key.scale: WheelScale.normal.rawValue,
            Key.toast: true,
            Key.reveal: false
        ])
    }

    private func modifierKey(_ key: String) -> ModifierKey {
        guard let raw = defaults.string(forKey: key), let value = ModifierKey(rawValue: raw) else {
            return .shift
        }
        return value
    }

    private func setModifierKey(_ value: ModifierKey, for key: String) {
        defaults.set(value.rawValue, forKey: key)
        announce()
    }

    private func storageKey(for mode: WheelMode) -> String {
        switch mode {
        case .convert: return Key.convertModifier
        case .tools: return Key.toolsModifier
        case .actions: return Key.actionsModifier
        }
    }

    func modifier(for mode: WheelMode) -> ModifierKey {
        modifierKey(storageKey(for: mode))
    }

    /// Assigning a key another wheel already owns swaps the two, so the three
    /// wheels always listen on three different keys.
    func setModifier(_ value: ModifierKey, for mode: WheelMode) {
        let current = modifier(for: mode)
        if let clash = WheelMode.allCases.first(where: { $0 != mode && modifier(for: $0) == value }) {
            defaults.set(current.rawValue, forKey: storageKey(for: clash))
        }
        defaults.set(value.rawValue, forKey: storageKey(for: mode))
        announce()
    }

    func mode(for modifier: ModifierKey) -> WheelMode? {
        WheelMode.allCases.first { self.modifier(for: $0) == modifier }
    }

    var scale: WheelScale {
        guard let raw = defaults.string(forKey: Key.scale),
              let value = WheelScale(rawValue: raw) else { return .normal }
        return value
    }

    func setScale(_ value: WheelScale) {
        defaults.set(value.rawValue, forKey: Key.scale)
        announce()
    }

    var showsToast: Bool { defaults.bool(forKey: Key.toast) }

    func setShowsToast(_ value: Bool) {
        defaults.set(value, forKey: Key.toast)
        announce()
    }

    var revealsAfterConvert: Bool { defaults.bool(forKey: Key.reveal) }

    func setRevealsAfterConvert(_ value: Bool) {
        defaults.set(value, forKey: Key.reveal)
        announce()
    }

    func reset() {
        defaults.set(ModifierKey.shift.rawValue, forKey: Key.convertModifier)
        defaults.set(ModifierKey.command.rawValue, forKey: Key.toolsModifier)
        defaults.set(ModifierKey.control.rawValue, forKey: Key.actionsModifier)
        defaults.set(WheelScale.normal.rawValue, forKey: Key.scale)
        defaults.set(true, forKey: Key.toast)
        defaults.set(false, forKey: Key.reveal)
        announce()
    }

    private func announce() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
