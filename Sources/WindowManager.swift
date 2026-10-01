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
            MainActor.assumeIsolated { self.unobserve(app.processIdentifier) }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self.bumpFocusedWindow(of: app) }
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
        if AX.string(element, kAXRoleAttribute) == kAXApplicationRole {
            if let win = AX.element(element, kAXFocusedWindowAttribute), let wid = AX.windowID(win) { bump(wid) }
        } else if let wid = AX.windowID(element) {
            bump(wid)
        }
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

    func currentWindows() -> [SwitcherWindow] {
        let includeMinimized = Settings.includeMinimized
        let includeHidden = Settings.includeHiddenApps
        let z = zOrder()
        let zIndex = Dictionary(z.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

        // Make sure the window that has focus right now is at the head of the list.
        bumpFocusedWindow(of: NSWorkspace.shared.frontmostApplication)
        let mruIndex = Dictionary(mru.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

        var result: [SwitcherWindow] = []
        var seen = Set<CGWindowID>()
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, app.processIdentifier != getpid(), !app.isTerminated else { continue }
            if app.isHidden && !includeHidden { continue }

            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            for win in AX.elements(appEl, kAXWindowsAttribute) {
                guard AX.string(win, kAXRoleAttribute) == kAXWindowRole else { continue }
                let title = AX.string(win, kAXTitleAttribute) ?? ""
                let subrole = AX.string(win, kAXSubroleAttribute)
                guard subrole == kAXStandardWindowSubrole || (subrole == kAXDialogSubrole && !title.isEmpty) else { continue }
                guard let wid = AX.windowID(win), !seen.contains(wid) else { continue }
                if let s = AX.size(win), s.width < 40 || s.height < 40 { continue }

                let minimized = AX.bool(win, kAXMinimizedAttribute) ?? false
                if minimized && !includeMinimized { continue }

                // Not minimized, not hidden, yet not on screen => it lives on another Space.
                if !minimized && !app.isHidden && zIndex[wid] == nil { continue }

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
