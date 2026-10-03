import AppKit
import CoreGraphics

private let tabKey: Int64 = 48

/// What a key means to the switcher and the Dock while they're up.
private enum Command: Equatable {
    case next, previous             // Tab / Shift+Tab
    case left, right, up, down      // arrow keys
    case activate, cancel           // Return or Enter / Esc
    case close, quit, minimize, hide // W, Q, M, H

    init?(keycode: Int64, shift: Bool) {
        switch keycode {
        case tabKey: self = shift ? .previous : .next
        case 123: self = .left
        case 124: self = .right
        case 126: self = .up
        case 125: self = .down
        case 36, 76: self = .activate
        case 53: self = .cancel
        case 13: self = .close
        case 12: self = .quit
        case 46: self = .minimize
        case 4: self = .hide
        default: return nil
        }
    }

    /// Holding these down acts once, not repeatedly.
    var actsOnce: Bool { [.close, .quit, .minimize, .hide].contains(self) }
}

/// Intercepts Cmd+Tab system-wide and drives the switcher while Cmd is held, and Option+Tab for the Dock.
@MainActor
final class HotkeyTap {
    private lazy var tap = EventTap(events: [.keyDown, .keyUp, .flagsChanged]) { [unowned self] type, event in
        handle(type: type, event: event)
    }
    private let controller: SwitcherController
    private let dock: DockController
    /// Keys whose key-down went to the Dock, so their key-up doesn't leak to the app underneath.
    private var swallowedKeyUps = Set<Int64>()

    /// True from the Cmd+Tab press until Cmd is released (or the switch is cancelled).
    var active = false

    init(controller: SwitcherController, dock: DockController) {
        self.controller = controller
        self.dock = dock
    }

    var isRunning: Bool { tap.isRunning }

    func start() -> Bool { tap.start() }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let flags = event.flags
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .flagsChanged:
            if active && !flags.contains(.maskCommand) {
                active = false
                // Queued (not called directly) so it stays ordered after begin()/move() calls.
                DispatchQueue.main.async { self.controller.commit() }
            }
            return pass

        case .keyDown:
            if !active, let routed = handleDock(keycode: keycode, flags: flags, event: event) {
                if routed { swallowedKeyUps.insert(keycode) }
                return routed ? nil : pass
            }
            if !active {
                guard Settings.enabled, keycode == tabKey, flags.contains(.maskCommand),
                      !flags.contains(.maskControl), !flags.contains(.maskAlternate) else { return pass }
                active = true
                let backwards = flags.contains(.maskShift)
                // Defer the (potentially slow) AX enumeration so the tap callback returns immediately.
                DispatchQueue.main.async { self.controller.begin(backwards: backwards) }
                return nil
            }
            handleSwitcher(Command(keycode: keycode, shift: flags.contains(.maskShift)), isRepeat: event.isRepeat)
            // Switcher is up: everything typed while Cmd is held belongs to us (so e.g. Cmd+Q can't leak through).
            return nil

        case .keyUp:
            if swallowedKeyUps.remove(keycode) != nil { return nil }
            return active ? nil : pass

        default:
            return pass
        }
    }

    /// A key typed while the switcher is up and Cmd is held.
    private func handleSwitcher(_ command: Command?, isRepeat: Bool) {
        if command == .activate || command == .cancel { active = false }
        // Queued, like begin(), so keys typed right after Cmd+Tab are handled after it.
        DispatchQueue.main.async { [self] in
            guard let command, !(command.actsOnce && isRepeat) else { return }
            switch command {
            case .next, .right: controller.move(1)
            case .previous, .left: controller.move(-1)
            case .down: controller.moveRow(1)
            case .up: controller.moveRow(-1)
            case .activate: controller.commit()
            case .cancel: controller.cancel()
            case .close: controller.closeSelected()
            case .quit: controller.quitSelected()
            case .minimize: controller.toggleMinimizeSelected()
            case .hide: controller.toggleHideSelected()
            }
        }
    }

    /// Option+Tab opens and closes the Dock; while it's up, it gets the navigation keys. Returns true to swallow the
    /// key, false to pass it on, or nil when the Dock doesn't care and the Cmd+Tab handling should run.
    private func handleDock(keycode: Int64, flags: CGEventFlags, event: CGEvent) -> Bool? {
        let command = flags.contains(.maskCommand), option = flags.contains(.maskAlternate), control = flags.contains(.maskControl)
        let optionTab = keycode == tabKey && option && !command && !control

        guard dock.isOpen else {
            guard optionTab, Settings.dockEnabled else { return nil }
            dock.open()
            return true
        }
        // A tile's context menu is up: the keyboard is the menu's.
        if dock.menuOpen { return false }
        if optionTab {
            dock.close()
            return true
        }
        // Cmd+Tab (and any other Cmd shortcut) closes the Dock and carries on as usual.
        if command {
            dock.close()
            return nil
        }
        // Typing anything else (M included: the Dock doesn't minimize) closes the Dock and the key goes to the app.
        guard let key = Command(keycode: keycode, shift: flags.contains(.maskShift)), key != .minimize else {
            dock.close()
            return false
        }
        if key.actsOnce && event.isRepeat { return true }
        switch key {
        case .next: dock.move(1)
        case .previous: dock.move(-1)
        case .right: dock.moveHorizontal(1)
        case .left: dock.moveHorizontal(-1)
        case .down: dock.moveDown()
        case .up: dock.moveUp()
        case .activate: dock.activate()
        case .cancel: dock.close()
        case .close: dock.closePreviewWindow()
        case .quit: dock.quitSelected()
        case .hide: dock.toggleHideSelected()
        case .minimize: break
        }
        return true
    }
}

private extension CGEvent {
    var isRepeat: Bool { getIntegerValueField(.keyboardEventAutorepeat) != 0 }
}
