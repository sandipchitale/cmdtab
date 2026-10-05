import AppKit
import CoreGraphics

private let tabKey: Int64 = 48

/// What a key means to the switcher and the Dock while they're up.
private enum Command: Equatable {
    case next, previous             // Tab / Shift+Tab
    case left, right, up, down      // arrow keys
    case activate, cancel           // Return or Enter / Esc
    case close, quit, minimize, hide // W, Q, M, H
    case group                      // G
    case newWindow                  // N
    case help                       // ? (Shift+/)
    case exchange                   // X: switch between Cmd+Tab and the Dock
    case tile                       // T: the tiling menu

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
        case 5: self = .group
        case 45: self = .newWindow
        case 44: self = .help
        case 7: self = .exchange
        case 17: self = .tile
        default: return nil
        }
    }

    /// Holding these down acts once, not repeatedly.
    var actsOnce: Bool { [.close, .quit, .minimize, .hide, .group, .newWindow, .help, .exchange, .tile].contains(self) }
}

/// Intercepts Cmd+Tab system-wide and drives the switcher while Cmd is held, and Option+Tab for the Dock.
@MainActor
final class HotkeyTap {
    private lazy var tap = EventTap(events: [.keyDown, .keyUp, .flagsChanged], onReenable: { [unowned self] in
        // Key and flag events from while the tap was off are gone: a Cmd release among them would leave us stuck.
        swallowedKeyUps.removeAll()
        releaseIfCommandIsUp(CGEventSource.flagsState(.combinedSessionState))
    }) { [unowned self] type, event in
        handle(type: type, event: event)
    }
    private let controller: SwitcherController
    private let dock: DockController
    /// Keys whose key-down went to the Dock, so their key-up doesn't leak to the app underneath.
    private var swallowedKeyUps = Set<Int64>()

    /// True from the Cmd+Tab press until Cmd is released (or the switch is cancelled).
    var active = false {
        didSet { if !active { switcherSticky = false } }
    }
    /// The switcher was opened from the Dock with X, without Cmd held: it stays up until Return, Esc or a click (or,
    /// once Cmd is pressed, until it's let go, as usual).
    private var switcherSticky = false
    /// The Dock was opened from the switcher with X while Cmd was held: until that Cmd is let go, keys typed with it
    /// are the Dock's (instead of closing it, as Cmd shortcuts otherwise do).
    private var commandHeldIntoDock = false

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
            let command = flags.contains(.maskCommand)
            if !command { commandHeldIntoDock = false }
            // Pressing Cmd in a switcher opened with X makes it switch on letting go, like one opened with Cmd+Tab.
            if switcherSticky && command { switcherSticky = false }
            releaseIfCommandIsUp(flags)
            return pass

        case .keyDown:
            // Safety valve: a missed Cmd release must never leave every key swallowed.
            releaseIfCommandIsUp(flags)
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
            // A tile's menu is up: the keyboard is the menu's. Cmd is still held from Cmd+Tab, and menus ignore Esc and
            // Return with Cmd, so the menu gets the keys without it.
            if controller.menuOpen { return withoutCommand(event) }
            let command = Command(keycode: keycode, shift: flags.contains(.maskShift))
            if command == .exchange {
                if !event.isRepeat { exchangeToDock(commandHeld: flags.contains(.maskCommand)) }
                swallowedKeyUps.insert(keycode)
                return nil
            }
            handleSwitcher(command, isRepeat: event.isRepeat)
            // Switcher is up: everything typed while Cmd is held belongs to us (so e.g. Cmd+Q can't leak through).
            return nil

        case .keyUp:
            if swallowedKeyUps.remove(keycode) != nil { return nil }
            if active && controller.menuOpen { return withoutCommand(event) }
            return active ? nil : pass

        default:
            return pass
        }
    }

    /// Switches (as when Cmd is let go) if the switcher is up but Cmd isn't down. While a tile's menu is up, letting go
    /// of Cmd doesn't switch; the menu decides when it closes.
    private func releaseIfCommandIsUp(_ flags: CGEventFlags) {
        guard active, !flags.contains(.maskCommand), !switcherSticky, !controller.menuOpen else { return }
        active = false
        // Queued (not called directly) so it stays ordered after begin()/move() calls.
        DispatchQueue.main.async { self.controller.commit() }
    }

    /// `event`, passed on as if Cmd weren't held.
    private func withoutCommand(_ event: CGEvent) -> Unmanaged<CGEvent> {
        event.flags.remove(.maskCommand)
        return Unmanaged.passUnretained(event)
    }

    /// A key typed while the switcher is up and Cmd is held.
    private func handleSwitcher(_ command: Command?, isRepeat: Bool) {
        if command == .activate || command == .cancel { active = false }
        // Queued, like begin(), so keys typed right after Cmd+Tab are handled after it.
        DispatchQueue.main.async { [self] in
            guard let command, !(command.actsOnce && isRepeat) else { return }
            switch command {
            case .next: controller.move(1)
            case .previous: controller.move(-1)
            case .right: controller.moveHorizontal(1)
            case .left: controller.moveHorizontal(-1)
            case .down: controller.moveDown()
            case .up: controller.moveUp()
            case .group: controller.toggleGrouping()
            case .newWindow: controller.newWindowForSelected()
            case .help: controller.toggleHelp()
            case .activate: controller.commit()
            case .cancel: controller.cancel()
            case .close: controller.closeSelected()
            case .quit: controller.quitSelected()
            case .minimize: controller.toggleMinimizeSelected()
            case .hide: controller.toggleHideSelected()
            case .tile: controller.showTilingMenuForSelected()
            case .exchange: break // handled before queueing (it hands the keyboard to the Dock)
            }
        }
    }

    /// X in the switcher: cancel it (no switch) and open the Dock in its place.
    private func exchangeToDock(commandHeld: Bool) {
        guard Settings.dockEnabled else { return NSSound.beep() }
        active = false
        commandHeldIntoDock = commandHeld
        // Queued, like the switcher's other keys, so it lands after begin().
        DispatchQueue.main.async { self.controller.cancel() }
        dock.open()
    }

    /// X in the Dock: close it and open the switcher in its place. Without Cmd held it stays up until Return, Esc or a
    /// click; with nothing to show it closes again rather than keeping the keyboard.
    private func exchangeToSwitcher(commandHeld: Bool) {
        guard Settings.enabled else { return NSSound.beep() }
        dock.close()
        commandHeldIntoDock = false
        active = true
        switcherSticky = !commandHeld
        DispatchQueue.main.async { [self] in
            controller.begin(backwards: false)
            if controller.isEmpty {
                active = false
                controller.cancel()
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
        // Cmd+Tab (and any other Cmd shortcut) closes the Dock and carries on as usual, unless this is the Cmd that was
        // held when X brought the Dock up from the switcher.
        if command && !commandHeldIntoDock {
            dock.close()
            return nil
        }
        // Typing anything else closes the Dock and the key goes to the app.
        guard let key = Command(keycode: keycode, shift: flags.contains(.maskShift)) else {
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
        case .newWindow: dock.newWindowForSelected()
        case .help: dock.toggleHelp()
        case .exchange: exchangeToSwitcher(commandHeld: command)
        // M looks up the app's windows, and T opens a menu that tracks modally: both run after this callback has
        // returned (an event tap that blocks gets disabled).
        case .minimize: DispatchQueue.main.async { self.dock.toggleMinimizeSelected() }
        // The Dock is already one icon per app; G means something only in the switcher. Kept, not typed into the app.
        case .group: NSSound.beep()
        case .tile: DispatchQueue.main.async { self.dock.showTilingMenuForSelected() }
        }
        return true
    }
}

private extension CGEvent {
    var isRepeat: Bool { getIntegerValueField(.keyboardEventAutorepeat) != 0 }
}
