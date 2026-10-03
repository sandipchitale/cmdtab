import AppKit
import CoreGraphics

private enum Key {
    static let tab: Int64 = 48
    static let q: Int64 = 12
    static let w: Int64 = 13
    static let m: Int64 = 46
    static let h: Int64 = 4
    static let escape: Int64 = 53
    static let returnKey: Int64 = 36
    static let enter: Int64 = 76
    static let left: Int64 = 123
    static let right: Int64 = 124
    static let down: Int64 = 125
    static let up: Int64 = 126
}

/// Intercepts Cmd+Tab system-wide and drives the switcher while Cmd is held, and Option+Tab for the Dock.
@MainActor
final class HotkeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
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

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { me.handle(type: type, event: event) }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

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
                guard Settings.enabled, keycode == Key.tab, flags.contains(.maskCommand),
                      !flags.contains(.maskControl), !flags.contains(.maskAlternate) else { return pass }
                active = true
                let backwards = flags.contains(.maskShift)
                // Defer the (potentially slow) AX enumeration so the tap callback returns immediately.
                DispatchQueue.main.async { self.controller.begin(backwards: backwards) }
                return nil
            }
            // Switcher is up: everything typed while Cmd is held belongs to us (so e.g. Cmd+Q can't leak through).
            if [Key.escape, Key.returnKey, Key.enter].contains(keycode) { active = false }
            // Holding Q, W, M or H must act once, not repeatedly.
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            DispatchQueue.main.async { [self] in
                switch keycode {
                case Key.tab: controller.move(flags.contains(.maskShift) ? -1 : 1)
                case Key.right: controller.move(1)
                case Key.left: controller.move(-1)
                case Key.down: controller.moveRow(1)
                case Key.up: controller.moveRow(-1)
                case Key.escape: controller.cancel()
                case Key.w where !isRepeat: controller.closeSelected()
                case Key.q where !isRepeat: controller.quitSelected()
                case Key.m where !isRepeat: controller.toggleMinimizeSelected()
                case Key.h where !isRepeat: controller.toggleHideSelected()
                case Key.returnKey, Key.enter: controller.commit()
                default: break
                }
            }
            return nil

        case .keyUp:
            if swallowedKeyUps.remove(keycode) != nil { return nil }
            return active ? nil : pass

        default:
            return pass
        }
    }

    /// Option+Tab opens and closes the Dock; while it's up, it gets the navigation keys. Returns true to swallow the
    /// key, false to pass it on, or nil when the Dock doesn't care and the Cmd+Tab handling should run.
    private func handleDock(keycode: Int64, flags: CGEventFlags, event: CGEvent) -> Bool? {
        let command = flags.contains(.maskCommand), option = flags.contains(.maskAlternate), control = flags.contains(.maskControl)
        let optionTab = keycode == Key.tab && option && !command && !control

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
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        switch keycode {
        case Key.tab: dock.move(flags.contains(.maskShift) ? -1 : 1)
        case Key.right: dock.move(1)
        case Key.left: dock.move(-1)
        case Key.down: dock.moveRow(1)
        case Key.up: dock.moveRow(-1)
        case Key.returnKey, Key.enter: dock.activate()
        case Key.escape: dock.close()
        case Key.q: if !isRepeat { dock.quitSelected() }
        case Key.h: if !isRepeat { dock.toggleHideSelected() }
        default:
            // Typing anything else closes the Dock and the key goes to the app underneath.
            dock.close()
            return false
        }
        return true
    }
}
