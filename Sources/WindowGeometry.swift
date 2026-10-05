import AppKit

/// Screens and window frames in Accessibility coordinates (origin at the top left of the primary screen, y down),
/// which is what `AX.frame` and `AX.setFrame` use. AppKit's screen frames have the origin at the bottom left.
@MainActor
enum WindowGeometry {
    /// `rect` flipped between AppKit and AX coordinates (the flip is its own inverse).
    static func flipped(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The screen showing most of `frame` (AX coordinates), or nil if it's on none of them.
    static func screen(around frame: CGRect) -> NSScreen? {
        func overlap(_ s: NSScreen) -> CGFloat {
            let r = flipped(s.frame).intersection(frame)
            return r.isNull ? 0 : r.width * r.height
        }
        guard let best = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 else { return nil }
        return best
    }

    /// A screen's usable area (no menu bar or Dock), in AX coordinates.
    static func visibleFrame(of screen: NSScreen) -> CGRect { flipped(screen.visibleFrame) }
}

/// The frames CmdTab has given windows (the green button's fill, the tiling menu's layouts) and where each window was
/// before, so that either one can put a window back, whichever moved it.
@MainActor
enum FrameHistory {
    private static var entries: [CGWindowID: (before: CGRect, applied: CGRect)] = [:]

    /// Moves the window to `frame`, remembering where it was.
    static func apply(_ frame: CGRect, to element: AXUIElement, id: CGWindowID) {
        let before = AX.frame(element)
        AX.setFrame(element, frame)
        // Apps may round the size (e.g. to whole terminal cells), so remember what it actually became.
        if let before { entries[id] = (before, AX.frame(element) ?? frame) }
    }

    /// Where the window was before CmdTab last moved it.
    static func previous(_ id: CGWindowID) -> CGRect? { entries[id]?.before }

    /// Puts the window back where it was before CmdTab last moved it. Returns false if there's nothing to go back to.
    @discardableResult
    static func restore(_ id: CGWindowID, _ element: AXUIElement) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        AX.setFrame(element, entry.before)
        return true
    }

    /// The frame CmdTab last gave the window, if the window still has it (not moved or resized since).
    static func stillApplied(_ id: CGWindowID, current: CGRect) -> CGRect? {
        guard let applied = entries[id]?.applied, nearlyEqual(current, applied) else { return nil }
        return applied
    }

    /// Whether CmdTab filled the window's screen with it (the green button, or Fill in the tiling menu) and it hasn't
    /// been moved or resized since, so that filling again should toggle it back instead.
    static func isFilled(_ id: CGWindowID, _ element: AXUIElement) -> Bool {
        guard let frame = AX.frame(element), let applied = stillApplied(id, current: frame),
              let screen = WindowGeometry.screen(around: frame) ?? NSScreen.main else { return false }
        return fills(applied, WindowGeometry.visibleFrame(of: screen))
    }

    /// Whether `frame` fills `area`: the same, give or take what an app rounds off (e.g. to whole terminal cells).
    private static func fills(_ frame: CGRect, _ area: CGRect) -> Bool {
        abs(frame.minX - area.minX) < 2 && abs(frame.minY - area.minY) < 2
            && area.width - frame.width < 40 && area.height - frame.height < 40 && frame.width <= area.width + 2
    }

    /// Forgets windows that no longer exist (their ids can come back for new windows).
    static func forgetClosedWindows() {
        guard !entries.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return }
        let alive = Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        entries = entries.filter { alive.contains($0.key) }
    }

    /// Within 2 points on every edge.
    static func nearlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
}
