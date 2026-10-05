import AppKit
import CoreGraphics

private let tabKey: Int64 = 48
private let deleteKey: Int64 = 51

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
    case view                       // .: app icons / window thumbnails
    case ring                       // R: ring / grid
    case search                     // F: type to search

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
        case 47: self = .view
        case 15: self = .ring
        case 3: self = .search
        default: return nil
        }
    }

    /// Holding these down acts once, not repeatedly.
    var actsOnce: Bool {
        [.close, .quit, .minimize, .hide, .group, .newWindow, .help, .exchange, .tile, .view, .ring, .search].contains(self)
    }
}

/// What a key does while searching, unless it's a command typed with ⌘.
private enum SearchKey {
    case navigate                   // Tab, the arrows, Return: as usual
    case end                        // Esc
    case deleteBackward             // Delete
    case clear                      // Cmd+Delete
    case text(String)
    case ignore
}

/// Intercepts Cmd+Tab system-wide and drives the switcher while Cmd is held, and Option+Tab for the Dock.
@MainActor
final class HotkeyTap {
    private lazy var tap = EventTap(events: [.keyDown, .keyUp, .flagsChanged], onReenable: { [unowned self] in
        // Key and flag events from while the tap was off are gone: a Cmd release among them would leave us stuck.
        swallowedKeyUps.removeAll()
        searchKeyHeld = nil
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
        didSet {
            if !active {
                switcherSticky = false
                switcherSearch = nil
            }
        }
    }
    /// The switcher was opened from the Dock with X, without Cmd held: it stays up until Return, Esc or a click (or,
    /// once Cmd is pressed, until it's let go, as usual).
    private var switcherSticky = false
    /// The Dock was opened from the switcher with X while Cmd was held: until that Cmd is let go, keys typed with it
    /// are the Dock's (instead of closing it, as Cmd shortcuts otherwise do).
    private var commandHeldIntoDock = false
    /// The switcher's search (F): keys type into it, or (read-only, after Esc) they're commands again, with what it
    /// found kept. Either way letting go of Cmd doesn't switch (Return does). Set here as F goes by, because the
    /// switcher's own work is queued and keys must be routed right away; the switcher reports the rest.
    private var switcherSearch: SearchState?
    /// The Cmd held when a search began: until it's let go, keys typed with it go into the search too. After that,
    /// Cmd with a key is a command, the same as in any search field.
    private var commandHeldIntoSearch = false
    /// The F that began a search, until it's let go: holding it down doesn't type it.
    private var searchKeyHeld: Int64?

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
            if !command {
                commandHeldIntoDock = false
                commandHeldIntoSearch = false
            }
            // Pressing Cmd in a switcher opened with X makes it switch on letting go, like one opened with Cmd+Tab.
            if switcherSticky && command { switcherSticky = false }
            releaseIfCommandIsUp(flags)
            return pass

        case .keyDown:
            // Safety valve: a missed Cmd release must never leave every key swallowed.
            releaseIfCommandIsUp(flags)
            // Likewise, a key typed without Cmd means the Cmd held into a search was let go, even if that went unseen.
            if !flags.contains(.maskCommand) { commandHeldIntoSearch = false }
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
            // Typing into the search: keys type, edit or move, except Cmd with a key once the Cmd held when it began
            // is let go (a command), and Cmd+Delete (which clears it).
            if switcherSearch == .typing && (!flags.contains(.maskCommand) || commandHeldIntoSearch || keycode == deleteKey),
               handleSwitcherSearch(keycode: keycode, flags: flags, event: event) { return nil }
            let command = Command(keycode: keycode, shift: flags.contains(.maskShift))
            if command == .exchange {
                if !event.isRepeat { exchangeToDock(commandHeld: flags.contains(.maskCommand)) }
                swallowedKeyUps.insert(keycode)
                return nil
            }
            if command == .search {
                if !event.isRepeat && switcherSearch != .typing {
                    beginSwitcherSearch(commandHeld: flags.contains(.maskCommand), keycode: keycode)
                }
                return nil
            }
            // A read-only search: Delete clears it, and Esc puts it away (or, with something in it, cancels as usual).
            if switcherSearch != nil {
                if keycode == deleteKey {
                    DispatchQueue.main.async { self.controller.clearSearch() }
                    return nil
                }
                if command == .cancel {
                    escapeSwitcherSearch()
                    return nil
                }
            }
            handleSwitcher(command, isRepeat: event.isRepeat)
            // Switcher is up: everything typed while Cmd is held belongs to us (so e.g. Cmd+Q can't leak through).
            return nil

        case .keyUp:
            if keycode == searchKeyHeld { searchKeyHeld = nil }
            if swallowedKeyUps.remove(keycode) != nil { return nil }
            if active && controller.menuOpen { return withoutCommand(event) }
            return active ? nil : pass

        default:
            return pass
        }
    }

    /// Switches (as when Cmd is let go) if the switcher is up but Cmd isn't down. While a tile's menu is up, letting go
    /// of Cmd doesn't switch; the menu decides when it closes. Nor while there's a search, where Return switches.
    private func releaseIfCommandIsUp(_ flags: CGEventFlags) {
        guard active, !flags.contains(.maskCommand), !switcherSticky, switcherSearch == nil, !controller.menuOpen else { return }
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
            case .view: controller.toggleThumbnails()
            case .ring: controller.toggleRing()
            case .exchange: break // handled before queueing (it hands the keyboard to the Dock)
            case .search: break   // handled before queueing (it changes what keys mean right away)
            }
        }
    }

    // MARK: - Search (F)

    /// What `keycode` does in a search, short of a Cmd command.
    private func searchKey(keycode: Int64, flags: CGEventFlags, event: CGEvent) -> SearchKey {
        switch Command(keycode: keycode, shift: flags.contains(.maskShift)) {
        case .next, .previous, .left, .right, .up, .down, .activate: return .navigate
        case .cancel: return .end
        default: break
        }
        // Cmd+Delete clears, as it deletes a whole line in a text field; with the Cmd held when the search began, it's
        // still a plain Delete.
        if keycode == deleteKey { return flags.contains(.maskCommand) && !commandHeldIntoSearch ? .clear : .deleteBackward }
        // Holding down the F that began the search doesn't type it.
        if keycode == searchKeyHeld && event.isRepeat { return .ignore }
        return KeyText.text(keycode: keycode, flags: flags).map(SearchKey.text) ?? .ignore
    }

    /// F in the switcher: from now on keys type into its search (a new one, or the read-only one there), and letting go
    /// of Cmd doesn't switch.
    private func beginSwitcherSearch(commandHeld: Bool, keycode: Int64) {
        switcherSearch = .typing
        commandHeldIntoSearch = commandHeld
        searchKeyHeld = keycode
        // Queued, like the switcher's other keys, so it lands after begin().
        DispatchQueue.main.async { [self] in
            guard !controller.beginSearch() else { return }
            // Nothing to search: as if F hadn't been pressed.
            switcherSearch = nil
            commandHeldIntoSearch = false
            releaseIfCommandIsUp(CGEventSource.flagsState(.combinedSessionState))
        }
    }

    /// A key typed into the switcher's search. False leaves it to the usual handling: Tab, the arrows and Return.
    private func handleSwitcherSearch(keycode: Int64, flags: CGEventFlags, event: CGEvent) -> Bool {
        switch searchKey(keycode: keycode, flags: flags, event: event) {
        case .navigate: return false
        case .end: escapeSwitcherSearch()
        case .clear: DispatchQueue.main.async { self.controller.clearSearch() }
        case .deleteBackward: DispatchQueue.main.async { self.controller.deleteBackward() }
        case .text(let text): DispatchQueue.main.async { self.controller.type(text) }
        case .ignore: break
        }
        return true
    }

    /// Esc with a search up: typing stops (the search turns read-only), or an empty search goes. A read-only one with
    /// something in it cancels the switcher instead, as Esc does without a search.
    private func escapeSwitcherSearch() {
        DispatchQueue.main.async { [self] in
            guard !controller.escapeSearch() else { return }
            active = false
            controller.cancel()
        }
    }

    /// The switcher's search changed: begun, read-only, or gone (by Esc, or because nothing it found is left).
    func switcherSearchChanged(_ state: SearchState?) {
        guard active else { return }
        let gone = switcherSearch != nil && state == nil
        switcherSearch = state
        guard gone else { return }
        // Keys are commands again. Letting go of Cmd switches if it's the Cmd held since before the search (not one
        // pressed later, as for Cmd+W); otherwise the switcher stays until Return, Esc or a click, as when X opened
        // it. With nothing left to switch to, it goes.
        switcherSticky = !commandHeldIntoSearch && !controller.isEmpty
        commandHeldIntoSearch = false
        releaseIfCommandIsUp(CGEventSource.flagsState(.combinedSessionState))
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
        let key = Command(keycode: keycode, shift: flags.contains(.maskShift))
        if dock.isTyping && (!command || commandHeldIntoSearch || keycode == deleteKey) {
            switch searchKey(keycode: keycode, flags: flags, event: event) {
            case .navigate: break // as usual, below
            case .end: _ = dock.escapeSearch(); return true
            case .clear: dock.clearSearch(); return true
            case .deleteBackward: dock.deleteBackward(); return true
            case .text(let text): dock.type(text); return true
            case .ignore: return true
            }
        } else if dock.isSearching && keycode == deleteKey {
            // A read-only search: Delete clears it.
            dock.clearSearch()
            return true
        } else if command && !commandHeldIntoDock && !(dock.isSearching && key?.actsOnce == true) {
            // Cmd+Tab (and any other Cmd shortcut) closes the Dock and carries on as usual, unless this is the Cmd
            // that was held when X brought the Dock up from the switcher, or it's searching and this is one of the
            // Dock's keys (typed with Cmd, since without it the key types into the search).
            dock.close()
            return nil
        }
        // Typing anything else closes the Dock and the key goes to the app; with a search up, it only beeps.
        guard let key else {
            if dock.isSearching {
                NSSound.beep()
                return true
            }
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
        // With a search up, Esc puts it away (or stops typing into it); a read-only one with something in it closes.
        case .cancel: if !dock.escapeSearch() { dock.close() }
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
        // Likewise . (the switcher's icons / thumbnails): the Dock is always icons.
        case .group, .view: NSSound.beep()
        case .tile: DispatchQueue.main.async { self.dock.showTilingMenuForSelected() }
        // Lays the Dock out again, after this callback has returned.
        case .ring: DispatchQueue.main.async { self.dock.toggleRing() }
        case .search:
            if dock.beginSearch() {
                commandHeldIntoSearch = command
                searchKeyHeld = keycode
            }
        }
        return true
    }
}

private extension CGEvent {
    var isRepeat: Bool { getIntegerValueField(.keyboardEventAutorepeat) != 0 }
}
