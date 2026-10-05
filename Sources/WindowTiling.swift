import AppKit

/// Window layouts like those in the menu of a window's green button (Fill, Center, halves, quarters, arrangements,
/// full screen, other displays), applied through Accessibility.
@MainActor
enum WindowTiling {
    /// A part of a screen's usable area, as fractions of it (from the top left).
    private struct Region {
        let x, y, width, height: CGFloat

        static let fill = Region(x: 0, y: 0, width: 1, height: 1)
        static let left = Region(x: 0, y: 0, width: 0.5, height: 1)
        static let right = Region(x: 0.5, y: 0, width: 0.5, height: 1)
        static let top = Region(x: 0, y: 0, width: 1, height: 0.5)
        static let bottom = Region(x: 0, y: 0.5, width: 1, height: 0.5)
        static let topLeft = Region(x: 0, y: 0, width: 0.5, height: 0.5)
        static let topRight = Region(x: 0.5, y: 0, width: 0.5, height: 0.5)
        static let bottomLeft = Region(x: 0, y: 0.5, width: 0.5, height: 0.5)
        static let bottomRight = Region(x: 0.5, y: 0.5, width: 0.5, height: 0.5)

        func frame(in area: CGRect) -> CGRect {
            CGRect(x: area.minX + x * area.width, y: area.minY + y * area.height,
                   width: width * area.width, height: height * area.height).integral
        }
    }

    /// The tiling menu for `window`. Arrangements also place the next of `others` (most recent first). `done` runs
    /// after a layout has been applied.
    static func menu(for window: SwitcherWindow, others: [SwitcherWindow], done: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        FrameHistory.forgetClosedWindows()
        let others = others.filter { $0.id != window.id && !$0.isMinimized }
        func item(_ title: String, enabled: Bool = true, _ layout: @escaping () -> Void) -> ActionItem {
            let item = ActionItem(title) {
                layout()
                done()
            }
            item.isEnabled = enabled
            return item
        }
        func place(_ regions: [Region]) -> () -> Void {
            { arrange(Array(([window] + others).prefix(regions.count)), in: regions) }
        }

        // Like the green button, Fill toggles: a window CmdTab filled (and that hasn't moved since) goes back instead.
        let filled = FrameHistory.isFilled(window.id, window.element)
        menu.addItem(filled ? item("Restore Size") { restore(window) } : item("Fill", place([.fill])))
        menu.addItem(item("Center") { center(window) })
        menu.addItem(.separator())

        let moveResize = NSMenu()
        moveResize.autoenablesItems = false
        for (title, region) in [("Left", Region.left), ("Right", .right), ("Top", .top), ("Bottom", .bottom)] {
            moveResize.addItem(item(title, place([region])))
        }
        moveResize.addItem(.separator())
        for (title, region) in [("Top Left", Region.topLeft), ("Top Right", .topRight),
                                ("Bottom Left", .bottomLeft), ("Bottom Right", .bottomRight)] {
            moveResize.addItem(item(title, place([region])))
        }
        moveResize.addItem(.separator())
        let arrangements: [(String, [Region])] = [
            ("Left & Right", [.left, .right]), ("Right & Left", [.right, .left]),
            ("Top & Bottom", [.top, .bottom]), ("Bottom & Top", [.bottom, .top]),
            ("Quarters", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ]
        for (title, regions) in arrangements {
            // Arranging needs that many windows in all.
            moveResize.addItem(item(title, enabled: others.count >= regions.count - 1, place(regions)))
        }
        let moveResizeItem = NSMenuItem(title: "Move & Resize", action: nil, keyEquivalent: "")
        moveResizeItem.submenu = moveResize
        menu.addItem(moveResizeItem)

        // While the window is filled, Restore Size above already does this.
        if !filled {
            menu.addItem(item("Return to Previous Size", enabled: FrameHistory.previous(window.id) != nil) { restore(window) })
        }
        menu.addItem(.separator())

        let isFullScreen = AX.bool(window.element, "AXFullScreen") ?? false
        menu.addItem(item(isFullScreen ? "Exit Full Screen" : "Enter Full Screen") {
            AX.set(window.element, "AXFullScreen", !isFullScreen)
        })
        let current = AX.frame(window.element).flatMap(WindowGeometry.screen(around:))
        let otherScreens = NSScreen.screens.filter { $0 != current }
        if !otherScreens.isEmpty { menu.addItem(.separator()) }
        for screen in otherScreens {
            menu.addItem(item("Move to \(screen.localizedName)") { move(window, to: screen) })
        }
        return menu
    }

    /// Puts `windows[i]` in `regions[i]` of the first window's screen.
    private static func arrange(_ windows: [SwitcherWindow], in regions: [Region]) {
        guard let first = windows.first, let area = usableArea(of: first) else { return }
        for (window, region) in zip(windows, regions) { setFrame(window, region.frame(in: area)) }
    }

    /// Keeps the size, centered on the screen's usable area.
    private static func center(_ window: SwitcherWindow) {
        guard let area = usableArea(of: window), let frame = AX.frame(window.element) else { return }
        let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        setFrame(window, CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                width: size.width, height: size.height).integral)
    }

    private static func restore(_ window: SwitcherWindow) {
        unminimize(window)
        FrameHistory.restore(window.id, window.element)
    }

    /// Same place relative to the usable area, on `screen`; shrunk to fit if needed.
    private static func move(_ window: SwitcherWindow, to screen: NSScreen) {
        guard let from = usableArea(of: window), let frame = AX.frame(window.element) else { return }
        let to = WindowGeometry.visibleFrame(of: screen)
        let size = CGSize(width: min(frame.width, to.width), height: min(frame.height, to.height))
        let fx = from.width > frame.width ? (frame.minX - from.minX) / (from.width - frame.width) : 0
        let fy = from.height > frame.height ? (frame.minY - from.minY) / (from.height - frame.height) : 0
        let x = to.minX + min(max(fx, 0), 1) * (to.width - size.width)
        let y = to.minY + min(max(fy, 0), 1) * (to.height - size.height)
        setFrame(window, CGRect(origin: CGPoint(x: x, y: y), size: size).integral)
    }

    /// The usable area of the screen holding most of the window.
    private static func usableArea(of window: SwitcherWindow) -> CGRect? {
        guard let frame = AX.frame(window.element) else { return nil }
        return (WindowGeometry.screen(around: frame) ?? NSScreen.main).map(WindowGeometry.visibleFrame(of:))
    }

    private static func setFrame(_ window: SwitcherWindow, _ frame: CGRect) {
        unminimize(window)
        FrameHistory.apply(frame, to: window.element, id: window.id)
    }

    private static func unminimize(_ window: SwitcherWindow) {
        if window.isMinimized { AX.set(window.element, kAXMinimizedAttribute, false) }
    }
}
