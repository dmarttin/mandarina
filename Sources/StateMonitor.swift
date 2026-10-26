import AppKit

/// Watches the mouse button, the modifier keys and the pointer by polling the
/// session state. Reading that state needs no Accessibility or Input Monitoring
/// permission, which an event tap would, so the wheel works on a fresh Mac with
/// nothing granted. A 40 Hz timer costs nothing and catches any press a human
/// can make.
final class StateMonitor {
    struct Handlers {
        var press: (NSPoint) -> Void
        var release: (NSPoint) -> Void
        var move: (NSPoint) -> Void
        var modifiers: (Set<ModifierKey>, NSPoint) -> Void
    }

    private var timer: Timer?
    private var handlers: Handlers?
    private var lastButton = false
    private var lastPoint = NSPoint.zero
    private var lastModifiers: Set<ModifierKey> = []

    /// Test hook: synthetic modifier events don't reach the session's flag
    /// state, so automation sets MANDARINA_TEST_MODIFIER to drive the flow.
    private let forced: ModifierKey? = {
        switch ProcessInfo.processInfo.environment["MANDARINA_TEST_MODIFIER"]?.lowercased() {
        case "shift": return .shift
        case "command": return .command
        case "control": return .control
        default: return nil
        }
    }()

    func start(_ handlers: Handlers) {
        stop()
        self.handlers = handlers
        let timer = Timer(timeInterval: 1.0 / 40.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.write("monitor: polling at 40 Hz, forced \(forced.map { String(describing: $0) } ?? "none")")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        handlers = nil
    }

    private var ticks = 0

    private func tick() {
        guard let handlers else { return }
        ticks += 1
        if ProcessInfo.processInfo.environment["MANDARINA_DEBUG"] == "1", ticks % 100 == 0 {
            Log.write("tick \(ticks) button \(CGEventSource.buttonState(.combinedSessionState, button: .left))")
        }
        let point = NSEvent.mouseLocation
        let button = CGEventSource.buttonState(.combinedSessionState, button: .left)
        var modifiers = StateMonitor.currentModifiers()
        if button, let forced { modifiers.insert(forced) }

        if button && !lastButton {
            handlers.press(point)
            // A modifier already held when the drag starts counts as pressed.
            if !modifiers.isEmpty {
                handlers.modifiers(modifiers, point)
            }
        } else if button && lastButton {
            if point != lastPoint {
                handlers.move(point)
            }
            if modifiers != lastModifiers {
                handlers.modifiers(modifiers, point)
            }
        } else if !button && lastButton {
            handlers.release(point)
        }

        lastButton = button
        lastPoint = point
        lastModifiers = modifiers
    }

    private func modifierSet(_ flags: CGEventFlags) -> Set<ModifierKey> {
        var set: Set<ModifierKey> = []
        if flags.contains(.maskShift) { set.insert(.shift) }
        if flags.contains(.maskCommand) { set.insert(.command) }
        if flags.contains(.maskControl) { set.insert(.control) }
        return set
    }

    /// The state as of now. Two independent reads of the same HID state, in
    /// case one of them lags: the session flags and the modifier key codes
    /// (left and right). Either saying "down" counts as down.
    static func currentModifiers() -> Set<ModifierKey> {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let state = CGEventSourceStateID.combinedSessionState
        var set: Set<ModifierKey> = []
        for key in ModifierKey.allCases {
            if flags.contains(key.flag) {
                set.insert(key)
                continue
            }
            if key.keyCodes.contains(where: { CGEventSource.keyState(state, key: $0) }) {
                set.insert(key)
            }
        }
        return set
    }
}
