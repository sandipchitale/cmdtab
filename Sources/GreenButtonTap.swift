import AppKit
import ApplicationServices

/// Makes a plain click on a window's green button toggle the window between filling its screen and its previous
/// frame, instead of entering full screen. Option-click enters full screen (the system's plain-click behavior).
@MainActor
final class GreenButtonTap {
    private lazy var tap = EventTap(events: [.leftMouseDown, .leftMouseUp]) { [unowned self] type, event in
        handle(type: type, event: event)
    }
    private let systemWide = AXUIElementCreateSystemWide()
    /// What happened to the last mouse-down on a green button, so its mouse-up gets the same treatment.
    private enum Click { case none, swallowed, optionRemoved }
    private var click = Click.none
    /// Windows this tap filled the screen with: the frame to restore, and the frame they got when filled.
    private var zoomed: [CGWindowID: (restore: CGRect, filled: CGRect)] = [:]

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
            guard Settings.greenButtonZooms, let window = greenButtonWindow(at: event.location) else { return pass }
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

    /// The window whose green button is at `point` (global display coordinates, top-left origin, as AX uses).
    private func greenButtonWindow(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element, AX.string(element, kAXSubroleAttribute) == "AXFullScreenButton" else { return nil }
        return AX.element(element, kAXWindowAttribute)
    }

    private func toggle(_ window: AXUIElement) {
        guard let id = AX.windowID(window), let frame = AX.frame(window) else { return }
        // Still where we put it: put it back. Moved or resized since (or never filled): fill the screen.
        if let entry = zoomed[id], Self.close(frame, entry.filled) {
            zoomed[id] = nil
            AX.setFrame(window, entry.restore)
            return
        }
        let target = Self.visibleFrame(around: frame)
        AX.setFrame(window, target)
        // Apps may round the size (e.g. to whole terminal cells), so remember what it actually became.
        zoomed[id] = (frame, AX.frame(window) ?? target)
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// The usable area (no menu bar or Dock) of the screen holding most of `frame`, in AX coordinates.
    private static func visibleFrame(around frame: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
        let screen = NSScreen.screens.max { a, b in
            flip(a.frame).intersection(frame).area < flip(b.frame).intersection(frame).area
        } ?? NSScreen.main
        return screen.map { flip($0.visibleFrame) } ?? frame
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
