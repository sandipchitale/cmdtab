import AppKit
import ApplicationServices

// Private but long-stable API used by every window switcher: maps an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

// Private but long-stable API used by window switchers to reach windows on other Spaces, which kAXWindowsAttribute omits:
// builds an element from a remote token (pid, 0, "coco", element id).
@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

// Private SkyLight APIs to list the windows on every Space.
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> UInt32
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: UInt32) -> CFArray?
@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
func CGSCopyWindowsWithOptionsAndTags(_ cid: UInt32, _ owner: UInt32, _ spaces: CFArray, _ options: UInt32,
                                      _ setTags: UnsafeMutablePointer<UInt64>, _ clearTags: UnsafeMutablePointer<UInt64>) -> CFArray?

// Private SkyLight API to turn the system's own Cmd+Tab / Cmd+Shift+Tab switcher on and off.
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ isEnabled: Bool) -> Int32

enum NativeSwitcher {
    private static let commandTab: Int32 = 1
    private static let commandShiftTab: Int32 = 2

    static func setEnabled(_ enabled: Bool) {
        _ = CGSSetSymbolicHotKeyEnabled(commandTab, enabled)
        _ = CGSSetSymbolicHotKeyEnabled(commandShiftTab, enabled)
    }
}

enum AX {
    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        value(el, attr) as? String
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        (value(el, attr) as? NSNumber)?.boolValue
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        value(el, attr) as? [AXUIElement] ?? []
    }

    /// An attribute holding an AXValue of `type` (a point, size, ...), unpacked.
    private static func unpacked<T>(_ el: AXUIElement, _ attr: String, _ type: AXValueType, _ empty: T) -> T? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var result = empty
        let ok = withUnsafeMutablePointer(to: &result) { AXValueGetValue(v as! AXValue, type, $0) }
        return ok ? result : nil
    }

    static func size(_ el: AXUIElement) -> CGSize? { unpacked(el, kAXSizeAttribute, .cgSize, CGSize.zero) }

    static func position(_ el: AXUIElement) -> CGPoint? { unpacked(el, kAXPositionAttribute, .cgPoint, CGPoint.zero) }

    /// The element's frame in AX coordinates (top-left origin on the primary screen).
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = position(el), let s = size(el) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func setFrame(_ el: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin, size = frame.size
        let pos = AXValueCreate(.cgPoint, &origin)!, sz = AXValueCreate(.cgSize, &size)!
        // Size, move, size again: a window may not grow past the screen edge until it has moved.
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sz)
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(el, &wid) == .success && wid != 0 ? wid : nil
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ attr: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(el, attr as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef) == .success
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(el, action as CFString) == .success
    }
}
