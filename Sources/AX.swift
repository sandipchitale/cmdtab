import AppKit
import ApplicationServices

// Private but long-stable API used by every window switcher: maps an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

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

    static func size(_ el: AXUIElement) -> CGSize? {
        guard let v = value(el, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(el, &wid) == .success && wid != 0 ? wid : nil
    }

    static func set(_ el: AXUIElement, _ attr: String, _ value: Bool) {
        AXUIElementSetAttributeValue(el, attr as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }
}
