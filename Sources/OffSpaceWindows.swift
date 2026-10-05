import AppKit
import ApplicationServices

/// Finds windows on other Spaces, which Accessibility doesn't list. An element we already hold keeps working once its
/// window leaves the Space, so remembered elements are the main source; the rest are looked up by brute force.
@MainActor
final class OffSpaceWindows {
    /// Window elements seen so far.
    private var known: [CGWindowID: (pid: pid_t, element: AXUIElement)] = [:]
    /// Windows already searched for by brute force (and not found), so each is searched for only once.
    private var searched: [pid_t: Set<CGWindowID>] = [:]

    func remember(_ win: AXUIElement, pid: pid_t) {
        if let wid = AX.windowID(win) { known[wid] = (pid, win) }
    }

    /// Remembers the windows every app lists right now (those of the current Space).
    func rememberCurrentSpace() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            for win in AX.elements(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) {
                remember(win, pid: app.processIdentifier)
            }
        }
    }

    func forget(pid: pid_t) {
        known = known.filter { $0.value.pid != pid }
        searched[pid] = nil
    }

    /// Normal windows on any Space (including full-screen ones) that aren't on screen now, by owning process. Also
    /// forgets remembered windows that no longer exist.
    func windowIDs(onScreen: Set<CGWindowID>) -> [pid_t: Set<CGWindowID>] {
        let result = Self.windowIDsOnOtherSpaces(onScreen: onScreen)
        let live = onScreen.union(result.values.joined())
        known = known.filter { live.contains($0.key) }
        return result
    }

    private static func windowIDsOnOtherSpaces(onScreen: Set<CGWindowID>) -> [pid_t: Set<CGWindowID>] {
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

    /// Elements for `wids` of app `pid`: remembered ones, or else found by trying the app's element ids one by one.
    func elements(pid: pid_t, wids: Set<CGWindowID>) -> [AXUIElement] {
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
}
