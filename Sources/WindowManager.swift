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
    /// Window elements seen so far. Accessibility won't list a window once it's on another Space, but an element we
    /// already hold keeps working, so this is how windows on other Spaces are usually found.
    private var known: [CGWindowID: (pid: pid_t, element: AXUIElement)] = [:]
    /// Off-Space windows already searched for by brute force (and not found), so each is searched for only once.
    private var searched: [pid_t: Set<CGWindowID>] = [:]
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
                let pid = app.processIdentifier
                self.unobserve(pid)
                self.known = self.known.filter { $0.value.pid != pid }
                self.searched[pid] = nil
            }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self.bumpFocusedWindow(of: app) }
        }
        // Remember the windows of each Space you visit, so they can be listed from other Spaces later.
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard Settings.includeAllSpaces else { return }
                for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
                    for win in AX.elements(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) {
                        self.remember(win, pid: app.processIdentifier)
                    }
                }
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

    fileprivate func handle(element: AXUIElement, notification: String) {
        let win = AX.string(element, kAXRoleAttribute) == kAXApplicationRole ? AX.element(element, kAXFocusedWindowAttribute) : element
        guard let win, let wid = AX.windowID(win) else { return }
        bump(wid)
        var pid: pid_t = 0
        if Settings.includeAllSpaces, AXUIElementGetPid(win, &pid) == .success { remember(win, pid: pid) }
    }

    private func remember(_ win: AXUIElement, pid: pid_t) {
        if let wid = AX.windowID(win) { known[wid] = (pid, win) }
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, pid != getpid(), app.activationPolicy == .regular, !app.isTerminated else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, _ in
            MainActor.assumeIsolated {
                WindowManager.shared.handle(element: element, notification: notification as String)
            }
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

    /// Normal windows on any Space (including full-screen ones) that aren't on screen now, by owning process.
    private func offSpaceWindows(onScreen: Set<CGWindowID>) -> [pid_t: Set<CGWindowID>] {
        let cid = CGSMainConnectionID()
        guard let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [:] }
        let spaces = displays.flatMap { ($0["Spaces"] as? [[String: Any]]) ?? [] }.compactMap { $0["ManagedSpaceID"] as? Int }
        var setTags: UInt64 = 0, clearTags: UInt64 = 0
        guard !spaces.isEmpty,
              let ids = CGSCopyWindowsWithOptionsAndTags(cid, 0, spaces as CFArray, 2, &setTags, &clearTags) as? [CGWindowID],
              let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        let onSomeSpace = Set(ids).subtracting(onScreen)
        var result: [pid_t: Set<CGWindowID>] = [:]
        for d in info where (d[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 {
            guard let wid = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value, onSomeSpace.contains(wid),
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            result[pid, default: []].insert(wid)
        }
        return result
    }

    /// Elements for windows on other Spaces: from `known`, or else by trying the app's element ids one by one.
    private func offSpaceElements(pid: pid_t, wids: Set<CGWindowID>) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var missing = Set<CGWindowID>()
        for wid in wids {
            if let k = known[wid], k.pid == pid, AX.windowID(k.element) == wid { found.append(k.element) } else { missing.insert(wid) }
        }
        missing.subtract(searched[pid] ?? [])
        guard !missing.isEmpty else { return found }
        defer { searched[pid, default: []].formUnion(missing) }

        // Element ids are small sequential numbers (a few hundred in practice). Stop early once everything is found,
        // and give up on an app that doesn't answer, so a hung app costs one timeout, not thousands.
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { b in
            b.storeBytes(of: pid, toByteOffset: 0, as: pid_t.self)
            b.storeBytes(of: Int32(0x636f636f), toByteOffset: 8, as: Int32.self) // "coco"
        }
        for id: UInt64 in 0..<2000 where !missing.isEmpty {
            token.withUnsafeMutableBytes { $0.storeBytes(of: id, toByteOffset: 12, as: UInt64.self) }
            guard let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            var role: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            if err == .cannotComplete { break }
            guard (role as? String) == kAXWindowRole, let wid = AX.windowID(el), missing.remove(wid) != nil else { continue }
            remember(el, pid: pid)
            found.append(el)
        }
        return found
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

        let offSpace = includeAllSpaces ? offSpaceWindows(onScreen: onScreen) : [:]
        let awayIDs = Set(offSpace.values.joined())
        if includeAllSpaces {
            let live = onScreen.union(awayIDs)
            known = known.filter { live.contains($0.key) }
        }

        var result: [SwitcherWindow] = []
        var seen = Set<CGWindowID>()
        for app in app.map({ [$0] }) ?? NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, app.processIdentifier != getpid(), !app.isTerminated else { continue }
            if app.isHidden && !includeHidden { continue }

            let pid = app.processIdentifier
            var windows = AX.elements(AXUIElementCreateApplication(pid), kAXWindowsAttribute)
            if includeAllSpaces {
                windows.forEach { remember($0, pid: pid) }
                let listed = Set(windows.compactMap(AX.windowID))
                if let away = offSpace[pid]?.subtracting(listed), !away.isEmpty {
                    windows += offSpaceElements(pid: pid, wids: away)
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

        let appEl = AXUIElementCreateApplication(w.app.processIdentifier)
        AX.set(appEl, kAXFrontmostAttribute, true)
        AX.set(w.element, kAXMainAttribute, true)
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        w.app.activate(options: [])
        bump(w.id)

        // Some apps re-raise their previously-key window while activating; raise ours once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            AX.set(w.element, kAXMainAttribute, true)
            AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        }
    }

    // MARK: - Closing

    /// Presses the window's close button. Returns false if it has none.
    func close(_ w: SwitcherWindow) -> Bool {
        if w.isMinimized { AX.set(w.element, kAXMinimizedAttribute, false) }
        guard let button = AX.element(w.element, kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// Minimizes or restores the window. Returns false if the window doesn't support it.
    func setMinimized(_ w: SwitcherWindow, _ minimized: Bool) -> Bool {
        let value = (minimized ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        return AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, value) == .success
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
