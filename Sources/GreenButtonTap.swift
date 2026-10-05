import AppKit
import ApplicationServices

/// Makes a plain click on a window's green button toggle the window between filling its screen and its previous
/// frame, instead of entering full screen. Option-click enters full screen (the system's plain-click behavior).
/// A double-click on a window's title bar does the same, instead of the system's Fill (which leaves a margin
/// around the window and that CmdTab couldn't put back).
@MainActor
final class GreenButtonTap {
    private lazy var tap = EventTap(events: [.leftMouseDown, .leftMouseUp]) { [unowned self] type, event in
        handle(type: type, event: event)
    }
    private let systemWide = AXUIElementCreateSystemWide()
    /// What happened to the last mouse-down on a green button, so its mouse-up gets the same treatment.
    private enum Click { case none, swallowed, optionRemoved }
    private var click = Click.none

    init() {
        // The hit test runs inside the tap callback; don't let a hung app stall every click.
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
    }

    func start() -> Bool { tap.start() }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .leftMouseDown:
            click = .none
            let doubleClick = event.getIntegerValueField(.mouseEventClickState) == 2
            guard Settings.greenButtonZooms, mightBeTitleBar(at: event.location, doubleClick: doubleClick) else { return pass }
            if doubleClick, !event.flags.contains(.maskAlternate), let window = titleBarWindow(at: event.location) {
                click = .swallowed
                DispatchQueue.main.async { self.toggle(window) }
                return nil
            }
            guard let window = greenButtonWindow(at: event.location) else { return pass }
            if event.flags.contains(.maskAlternate) {
                // Without Option, the click is the system's own: full screen.
                click = .optionRemoved
                event.flags.remove(.maskAlternate)
                return pass
            }
            click = .swallowed
            // Resize outside the tap callback so the click itself isn't held up.
            DispatchQueue.main.async { self.toggle(window) }
            return nil
        case .leftMouseUp:
            defer { click = .none }
            switch click {
            case .swallowed: return nil
            case .optionRemoved: event.flags.remove(.maskAlternate)
            case .none: break
            }
        default:
            break
        }
        return pass
    }

    /// A cheap check, before the Accessibility lookups (which ask the app under the pointer, and can stall): whether
    /// `point` is in the title bar strip of the frontmost window there, or, unless it's a double-click, near the
    /// top left corner where the green button is. The window list comes from the window server, not the app.
    private func mightBeTitleBar(at point: CGPoint, doubleClick: Bool) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return true }
        for window in info {
            guard let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.contains(point) else { continue }
            // The first window under the pointer is the one clicked; menus, the Dock, etc. aren't on layer 0.
            guard (window[kCGWindowLayer as String] as? Int) == 0 else { return false }
            let down = point.y - bounds.minY, right = point.x - bounds.minX
            return down < 40 && (doubleClick || right < 100)
        }
        return false
    }

    /// The window whose green button is at `point` (global display coordinates, top-left origin, as AX uses).
    private func greenButtonWindow(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element, AX.string(element, kAXSubroleAttribute) == "AXFullScreenButton" else { return nil }
        return AX.element(element, kAXWindowAttribute)
    }

    /// Roles of things in a title bar that do their own thing on a double-click (buttons, tabs, fields, ...).
    private static let controlRoles: Set<String> = [
        "AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea",
        "AXComboBox", "AXTabGroup", "AXSlider", "AXMenuBar", "AXMenuBarItem", "AXScrollBar",
    ]

    /// The window whose title bar is at `point`: inside its top strip, on something other than a control.
    private func titleBarWindow(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element, let role = AX.string(element, kAXRoleAttribute), !Self.controlRoles.contains(role),
              let window = role == kAXWindowRole ? element : AX.element(element, kAXWindowAttribute),
              AX.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              AX.element(window, kAXZoomButtonAttribute) != nil,
              let frame = AX.frame(window), point.y - frame.minY >= 0, point.y - frame.minY < 40 else { return nil }
        return window
    }

    private func toggle(_ window: AXUIElement) {
        guard let id = AX.windowID(window), let frame = AX.frame(window) else { return }
        FrameHistory.forgetClosedWindows()
        // Filled by CmdTab (with this button, or Fill in the tiling menu) and not moved or resized since: put it back.
        // Otherwise fill the screen.
        if FrameHistory.isFilled(id, window) {
            FrameHistory.restore(id, window)
        } else {
            FrameHistory.apply(Self.visibleFrame(around: frame), to: window, id: id)
        }
    }

    /// The usable area (no menu bar or Dock) of the screen holding most of `frame`, in AX coordinates.
    private static func visibleFrame(around frame: CGRect) -> CGRect {
        let screen = WindowGeometry.screen(around: frame) ?? NSScreen.main
        return screen.map(WindowGeometry.visibleFrame(of:)) ?? frame
    }
}
