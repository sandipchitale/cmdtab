import AppKit
import ApplicationServices

struct SwitcherWindow {
    let id: CGWindowID
    let element: AXUIElement
    let app: NSRunningApplication
    let title: String
    var isMinimized: Bool
    /// Snapshot of `app.isHidden`, updated by the switcher itself because hide()/unhide() apply asynchronously.
    var isAppHidden: Bool
}

/// Enumerates switchable windows and keeps a most-recently-used order, like Windows' Alt+Tab.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var mru: [CGWindowID] = []
    private var observers: [pid_t: AXObserver] = [:]
    private let offSpace = OffSpaceWindows()
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        // Don't let one hung app freeze the switcher.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)

        mru = zOrder()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observe(app)
        }
        bumpFocusedWindow(of: NSWorkspace.shared.frontmostApplication)

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                // Freshly launched apps often aren't ready for AX observers yet; retry a few times.
                for delay in [0.5, 2.0, 5.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.observe(app) }
                }
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self.unobserve(app.processIdentifier)
                self.offSpace.forget(pid: app.processIdentifier)
            }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self.bumpFocusedWindow(of: app) }
        }
        // Remember the windows of each Space you visit, so they can be listed from other Spaces later.
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if Settings.includeAllSpaces { self.offSpace.rememberCurrentSpace() }
            }
        }
    }

    // MARK: - MRU tracking

    private func bump(_ wid: CGWindowID) {
        mru.removeAll { $0 == wid }
        mru.insert(wid, at: 0)
        if mru.count > 1000 { mru.removeLast(mru.count - 1000) }
    }

    private func bumpFocusedWindow(of app: NSRunningApplication?) {
        guard let app else { return }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        if let win = AX.element(appEl, kAXFocusedWindowAttribute), let wid = AX.windowID(win) {
            bump(wid)
        }
    }

    /// A focus change reported by an app's AXObserver: `element` is the window, or the app (whose focused window it is).
    fileprivate func handle(element: AXUIElement) {
        let win = AX.string(element, kAXRoleAttribute) == kAXApplicationRole ? AX.element(element, kAXFocusedWindowAttribute) : element
        guard let win, let wid = AX.windowID(win) else { return }
        bump(wid)
        var pid: pid_t = 0
        if Settings.includeAllSpaces, AXUIElementGetPid(win, &pid) == .success { offSpace.remember(win, pid: pid) }
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, pid != getpid(), app.activationPolicy == .regular, !app.isTerminated else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, _ in
            MainActor.assumeIsolated { WindowManager.shared.handle(element: element) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let appEl = AXUIElementCreateApplication(pid)
        var ok = false
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXApplicationActivatedNotification] {
            if AXObserverAddNotification(observer, appEl, n as CFString, nil) == .success { ok = true }
        }
        guard ok else { return } // app not ready yet; a later retry will pick it up
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func unobserve(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    // MARK: - Enumeration

    /// On-screen normal windows of the current Space, front to back.
    private func zOrder() -> [CGWindowID] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { d in
            guard (d[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }

    func onScreenWindowIDs() -> Set<CGWindowID> { Set(zOrder()) }

    /// Whether a window is minimized, or nil if the app won't say. A window that's on screen isn't minimized, whatever
    /// the app claims (Electron apps sometimes say it is).
    func isMinimized(_ element: AXUIElement, id: CGWindowID, onScreen: Set<CGWindowID>) -> Bool? {
        AX.bool(element, kAXMinimizedAttribute).map { $0 && !onScreen.contains(id) }
    }

    /// Switchable windows, most recently used first: of every app, or only of `app` (for the Dock's previews).
    func currentWindows(of app: NSRunningApplication? = nil) -> [SwitcherWindow] {
        let includeMinimized = Settings.includeMinimized
        let includeHidden = Settings.includeHiddenApps
        let includeAllSpaces = Settings.includeAllSpaces
        let z = zOrder()
        let onScreen = Set(z)
        let zIndex = Dictionary(z.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

        // Make sure the window that has focus right now is at the head of the list.
        bumpFocusedWindow(of: NSWorkspace.shared.frontmostApplication)
        let mruIndex = Dictionary(mru.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

        let away = includeAllSpaces ? offSpace.windowIDs(onScreen: onScreen) : [:]
        let awayIDs = Set(away.values.joined())

        var result: [SwitcherWindow] = []
        var seen = Set<CGWindowID>()
        for app in app.map({ [$0] }) ?? NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, app.processIdentifier != getpid(), !app.isTerminated else { continue }
            if app.isHidden && !includeHidden { continue }

            let pid = app.processIdentifier
            var windows = AX.elements(AXUIElementCreateApplication(pid), kAXWindowsAttribute)
            if includeAllSpaces {
                windows.forEach { offSpace.remember($0, pid: pid) }
                let listed = Set(windows.compactMap(AX.windowID))
                if let missing = away[pid]?.subtracting(listed), !missing.isEmpty {
                    windows += offSpace.elements(pid: pid, wids: missing)
                }
            }
            for win in windows {
                guard AX.string(win, kAXRoleAttribute) == kAXWindowRole else { continue }
                let title = AX.string(win, kAXTitleAttribute) ?? ""
                let subrole = AX.string(win, kAXSubroleAttribute)
                guard subrole == kAXStandardWindowSubrole || (subrole == kAXDialogSubrole && !title.isEmpty) else { continue }
                guard let wid = AX.windowID(win), !seen.contains(wid) else { continue }
                if let s = AX.size(win), s.width < 40 || s.height < 40 { continue }

                let minimized = isMinimized(win, id: wid, onScreen: onScreen) ?? false
                if minimized && !includeMinimized { continue }

                // Not minimized, not hidden, yet not on screen => it lives on another Space (or is a background tab).
                if !minimized && !app.isHidden && zIndex[wid] == nil && !awayIDs.contains(wid) { continue }

                seen.insert(wid)
                result.append(SwitcherWindow(id: wid, element: win, app: app,
                                             title: title.isEmpty ? (app.localizedName ?? "Untitled") : title,
                                             isMinimized: minimized, isAppHidden: app.isHidden))
            }
        }

        func rank(_ w: SwitcherWindow) -> (Int, Int, Int) {
            (w.isMinimized ? 1 : 0, mruIndex[w.id] ?? Int.max, zIndex[w.id] ?? Int.max)
        }
        result.sort { rank($0) < rank($1) }
        return result
    }

    // MARK: - Focusing

    func focus(_ w: SwitcherWindow) {
        if w.isAppHidden || w.app.isHidden { w.app.unhide() }
        if w.isMinimized { AX.set(w.element, kAXMinimizedAttribute, false) }

        func raise() {
            AX.set(w.element, kAXMainAttribute, true)
            AX.perform(w.element, kAXRaiseAction)
        }
        AX.set(AXUIElementCreateApplication(w.app.processIdentifier), kAXFrontmostAttribute, true)
        raise()
        w.app.activate(options: [])
        bump(w.id)

        // Some apps re-raise their previously-key window while activating; raise ours once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { raise() }
    }

    // MARK: - New windows

    /// Opens a new window of `app` through its own "New Window" menu item, found by name (its shortcut differs from
    /// app to app, and Cmd+N or Cmd+Shift+N mean other things in some). Brings the app forward first, so the window
    /// opens in front. Returns false if the app has no such item.
    func newWindow(of app: NSRunningApplication) -> Bool {
        guard let item = Self.newWindowMenuItem(of: app) else { return false }
        if app.isHidden { app.unhide() }
        app.activate(options: [])
        return AX.perform(item, kAXPressAction)
    }

    /// The enabled "New Window" item (or "New <something> Window", like Finder's) in one of the app's menus, preferring
    /// an exact "New Window" and skipping private / incognito ones. For one that opens a submenu (Terminal's), its
    /// first enabled item.
    private static func newWindowMenuItem(of app: NSRunningApplication) -> AXUIElement? {
        guard let menuBar = AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute) else { return nil }
        func enabled(_ el: AXUIElement) -> Bool { AX.bool(el, kAXEnabledAttribute) ?? false }
        func items(of el: AXUIElement) -> [AXUIElement] {
            AX.elements(el, kAXChildrenAttribute).flatMap { AX.elements($0, kAXChildrenAttribute) }
                .filter { AX.string($0, kAXRoleAttribute) == kAXMenuItemRole }
        }
        var best: AXUIElement?
        // Skip the Apple menu, which comes first.
        for menu in AX.elements(menuBar, kAXChildrenAttribute).dropFirst() {
            for item in items(of: menu) where enabled(item) {
                let title = (AX.string(item, kAXTitleAttribute) ?? "").lowercased()
                guard title == "new window" || (title.hasPrefix("new ") && title.hasSuffix(" window")),
                      !title.contains("incognito"), !title.contains("private") else { continue }
                if title == "new window" { best = item; break }
                if best == nil { best = item }
            }
            if let best, AX.string(best, kAXTitleAttribute)?.lowercased() == "new window" { break }
        }
        guard let best else { return nil }
        // An item that opens a submenu: its first enabled item.
        let submenuItems = items(of: best)
        return submenuItems.isEmpty ? best : submenuItems.first(where: enabled)
    }

    // MARK: - Closing

    /// Presses the window's close button. Returns false if it has none.
    func close(_ w: SwitcherWindow) -> Bool {
        if w.isMinimized { AX.set(w.element, kAXMinimizedAttribute, false) }
        guard let button = AX.element(w.element, kAXCloseButtonAttribute) else { return false }
        return AX.perform(button, kAXPressAction)
    }

    /// Minimizes or restores the window. Returns false if the window doesn't support it.
    func setMinimized(_ w: SwitcherWindow, _ minimized: Bool) -> Bool {
        AX.set(w.element, kAXMinimizedAttribute, minimized)
    }

    /// Minimizes the window, or restores it if it's minimized. Restoring a window of a hidden app also unhides the app
    /// (like clicking its Dock thumbnail), so the window ends up in plain view. Returns false if the window can't.
    func toggleMinimized(_ w: SwitcherWindow) -> Bool {
        guard setMinimized(w, !w.isMinimized) else { return false }
        if w.isMinimized && w.isAppHidden { setHidden(w.app, false) }
        return true
    }

    /// Hides or unhides the app, like Cmd+H / clicking it in the Dock.
    /// hide()/unhide() return false even when they work, so their result is ignored.
    func setHidden(_ app: NSRunningApplication, _ hidden: Bool) {
        if hidden { app.hide() } else { app.unhide() }
    }

    /// Asks the app to quit, as if you'd pressed Cmd+Q in it. Finder can't be quit this way.
    func quit(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier != "com.apple.finder" else { return false }
        return app.terminate()
    }
}
