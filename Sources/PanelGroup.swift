import AppKit

/// The switcher grid on one or more displays: one panel per display it's shown on, all showing the same tiles and
/// selection. The first panel is on the display with the pointer (or the active window) and drives grid navigation.
@MainActor
final class PanelGroup {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onRightClick: ((Int, NSEvent) -> Void)?

    private var panels: [SwitcherPanel] = []
    private var shownPanels: ArraySlice<SwitcherPanel> = []
    /// The displays for this session, picked when the grid first appears so redraws don't make it jump.
    private var screens: [NSScreen] = []

    var isVisible: Bool { shownPanels.first?.isVisible ?? false }
    var columns: Int { shownPanels.first?.columns ?? 1 }

    /// Whether `point` (screen coordinates) is on one of the shown panels.
    func contains(_ point: NSPoint) -> Bool {
        shownPanels.contains { $0.isVisible && NSMouseInRect(point, $0.frame, false) }
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel()
        panel.onHover = { [weak self] i in self?.onHover?(i) }
        panel.onClick = { [weak self] i in self?.onClick?(i) }
        panel.onRightClick = { [weak self] i, event in self?.onRightClick?(i, event) }
        return panel
    }

    /// Shows the grid on every display, or on the one with the pointer or the active window, per the settings.
    func show(tiles: [SwitcherTile], selected: Int, thumbnails: Bool,
              dockStyle: Bool = false, separators: [Int: TileSeparator] = [:], iconsLikeDock: (count: Int, gaps: Int)? = nil) {
        if screens.isEmpty {
            let pointer = NSScreen.containing(NSEvent.mouseLocation)
            if Settings.showOnAllDisplays {
                screens = [pointer] + NSScreen.screens.filter { $0 != pointer }
            } else {
                screens = [Settings.switcherDisplay == "activeWindow" ? Self.activeWindowScreen() ?? pointer : pointer]
            }
        }
        while panels.count < screens.count { panels.append(makePanel()) }
        panels[screens.count...].forEach { $0.dismiss() }
        shownPanels = panels[..<screens.count]
        for (panel, screen) in zip(shownPanels, screens) {
            panel.show(tiles: tiles, selected: selected, on: screen, thumbnails: thumbnails,
                       dockStyle: dockStyle, separators: separators, iconsLikeDock: iconsLikeDock)
        }
    }

    func setSelected(_ index: Int) {
        if isVisible { shownPanels.forEach { $0.setSelected(index) } }
    }

    func setThumbnail(_ image: CGImage, for id: CGWindowID) {
        shownPanels.forEach { $0.setThumbnail(image, for: id) }
    }

    func dismiss() {
        panels.forEach { $0.dismiss() }
        shownPanels = []
        screens = []
    }

    /// The display showing most of the frontmost window (the one you're switching away from).
    private static func activeWindowScreen() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let win = AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              let axFrame = AX.frame(win), let primary = NSScreen.screens.first else { return nil }
        // AX uses top-left origin on the primary display; AppKit uses bottom-left.
        let frame = NSRect(x: axFrame.minX, y: primary.frame.maxY - axFrame.maxY, width: axFrame.width, height: axFrame.height)
        func overlap(_ s: NSScreen) -> CGFloat { let r = s.frame.intersection(frame); return r.isNull ? 0 : r.width * r.height }
        guard let best = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 else { return nil }
        return best
    }
}
