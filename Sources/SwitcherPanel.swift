import AppKit

/// A borderless panel that floats above everything on every Space and never becomes key, so it never steals focus
/// from the app you're leaving.
@MainActor
class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // The window itself stays light; contentAppearance styles what's inside. A dark window gets a hard dark
        // outline traced around its shadow shape, which shows up as artifacts at the rounded corners.
        appearance = NSAppearance(named: .aqua)
    }

    /// The appearance of the panel's content.
    var contentAppearance: NSAppearance {
        get { contentView?.effectiveAppearance ?? NSApp.effectiveAppearance }
        set { contentView?.appearance = newValue }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSScreen {
    /// The screen containing `point` (screen coordinates), falling back to the main screen.
    static func containing(_ point: NSPoint) -> NSScreen {
        screens.first { NSMouseInRect(point, $0.frame, false) } ?? main ?? screens[0]
    }
}

/// One tile in the grid: a window (Cmd+Tab) or a Dock item (Option+Tab).
struct SwitcherTile {
    let icon: NSImage
    /// Shown under the selected icon in icon view.
    let name: String
    /// The hover tooltip in icon view, and the header in thumbnail view.
    let title: String
    var isMinimized = false
    var isAppHidden = false
    /// Draws the Dock's running-app dot under the icon.
    var isRunning = false
    /// The window to show a snapshot of in thumbnail view.
    var windowID: CGWindowID?
}

extension SwitcherTile {
    init(window w: SwitcherWindow) {
        self.init(icon: w.app.icon ?? NSImage(), name: w.app.localizedName ?? w.title, title: w.title,
                  isMinimized: w.isMinimized, isAppHidden: w.isAppHidden, windowID: w.id)
    }
}

/// `index` moved by `delta`, wrapping around a list of `count` items.
func wrapped(_ index: Int, by delta: Int, count: Int) -> Int {
    ((index + delta) % count + count) % count
}

/// Where a panel goes on its screen.
enum PanelPlacement {
    case centered
    /// Hanging below a point (screen coordinates), centered on it: the Dock's window previews.
    case below(topCenter: NSPoint)
}

/// The floating Alt+Tab-style grid.
@MainActor
final class SwitcherPanel: OverlayPanel {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onRightClick: ((Int, NSEvent) -> Void)?
    private(set) var columns = 1

    /// Holds the tiles; sits inside the glass (or the fallback blur).
    private let content = NSView()
    /// Only in the pre-Liquid Glass fallback: tones down the blur's see-through look.
    private var tint: NSView?
    /// A hairline in the opposite tone of the panel, so it doesn't melt into a matching light or dark background.
    private let border = NSView()
    private let tooltip = TooltipWindow()
    /// In icon view, the selected item's name floats in a bubble above its icon, like the Dock's.
    private let nameBubble = TooltipWindow()
    private var pendingTooltip: DispatchWorkItem?
    private var tooltipIndex: Int?
    private var items: [SwitcherItemView] = []
    /// Dividers drawn between tiles in the single-row layout.
    private var decorations: [NSView] = []
    private var tilesShown: [SwitcherTile] = []
    private var mouseAtShow = NSPoint.zero
    private var showsThumbnails = false

    private let padding: CGFloat = 20
    private let cornerRadius: CGFloat = 26
    /// The margin around icon tiles. Thumbnail tiles carry their own title row, so they get `padding`.
    private static let iconPadding: CGFloat = 14
    /// In the Dock-style row: the space between icons, and the extra gap for a divider, per icon side.
    private static let rowSpacingRatio: CGFloat = 0.1, gapRatio: CGFloat = 0.5

    /// The icon size of a Dock-style row of `count` items with `gaps` dividers across `area`, at most 120.
    static func dockIconSide(count: Int, gaps: Int, area: NSRect) -> CGFloat {
        let n = CGFloat(max(count, 1))
        let fitted = (area.width * 0.92 - iconPadding * 2) / (n + rowSpacingRatio * (n - 1) + gapRatio * CGFloat(gaps))
        return min(fitted.rounded(.down), 120)
    }

    override init() {
        super.init()
        isFloatingPanel = true

        if #available(macOS 26.0, *) {
            // Liquid Glass, as used by the system Cmd+Tab switcher.
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            contentView = glass
            // The glass draws its own edge; the window shadow adds a dark outline that bunches up at the corners.
            hasShadow = false
        } else {
            let background = NSVisualEffectView()
            background.material = .popover
            background.blendingMode = .behindWindow
            background.state = .active
            // A layer corner radius doesn't clip behind-window blur (square corners leak out); a mask image does,
            // and the window shadow follows it.
            background.maskImage = roundedMaskImage(radius: cornerRadius)
            contentView = background

            // Its color is resolved per appearance in show().
            let tint = NSView()
            tint.wantsLayer = true
            tint.layer?.cornerRadius = cornerRadius
            tint.autoresizingMask = [.width, .height]
            background.addSubview(tint)
            self.tint = tint
            content.autoresizingMask = [.width, .height]
            background.addSubview(content)
        }

        border.wantsLayer = true
        border.layer?.cornerRadius = cornerRadius
        border.layer?.borderWidth = 1
        border.autoresizingMask = [.width, .height]
        content.addSubview(border)
    }

    /// Lays out `tiles` as a grid, or (with `dockStyle`) like the Dock: one row whose icons shrink to fit the width,
    /// with section dividers in front of the tiles listed in `dividers`, and the selected name above its icon.
    /// `iconsLikeDock` (count and dividers of the Dock) sizes icon tiles the same as the Dock-style row would be.
    /// `placement` and `maxTileWidth` let the Dock hang a small strip of window previews under an icon.
    func show(tiles: [SwitcherTile], selected: Int, on screen: NSScreen, thumbnails: Bool,
              dockStyle: Bool = false, dividers: Set<Int> = [], iconsLikeDock: (count: Int, gaps: Int)? = nil,
              placement: PanelPlacement = .centered, maxTileWidth: CGFloat? = nil) {
        hideTooltip()
        tilesShown = tiles
        items.forEach { $0.removeFromSuperview() }
        items = []
        decorations.forEach { $0.removeFromSuperview() }
        decorations = []

        let mouse = NSEvent.mouseLocation
        mouseAtShow = mouse
        let area = screen.visibleFrame

        switch Settings.appearance {
        case "light": contentAppearance = NSAppearance(named: .aqua)!
        case "dark": contentAppearance = NSAppearance(named: .darkAqua)!
        default: contentAppearance = NSApp.effectiveAppearance // follow the system
        }
        let dark = contentAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        border.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.3) : NSColor.black.withAlphaComponent(0.25)).cgColor
        if let tint {
            contentAppearance.performAsCurrentDrawingAppearance {
                tint.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55).cgColor
            }
        }

        // Thumbnail tiles carry their own title; icon tiles show the selected tile's name in a bubble above it.
        showsThumbnails = thumbnails
        let spacing: CGFloat = 12
        var iconSides: [CGFloat] = [120, 104, 88, 76, 64]
        if let dock = iconsLikeDock {
            // The Dock's icon size first, then smaller sizes in case that many windows don't fit.
            let side = max(Self.dockIconSide(count: dock.count, gaps: dock.gaps, area: area), 36)
            iconSides = [side] + iconSides.filter { $0 < side }
        }
        var thumbnailWidths: [CGFloat] = [320, 280, 240, 200, 170, 140]
        if let maxTileWidth {
            // At least the smallest size, even if it's wider than asked.
            let fitting = thumbnailWidths.filter { $0 <= maxTileWidth }
            thumbnailWidths = fitting.isEmpty ? [thumbnailWidths[thumbnailWidths.count - 1]] : fitting
        }
        let sizes: [CGSize] = thumbnails
            ? thumbnailWidths.map { CGSize(width: $0, height: ($0 * 0.62 + SwitcherItemView.headerHeight).rounded()) }
            : iconSides.map { CGSize(width: $0, height: $0) }

        // The same margin on all four sides.
        let edge = thumbnails ? padding : Self.iconPadding
        var frames: [NSRect] = []
        var dividerXs: [CGFloat] = []
        var tile = sizes[0]
        var width: CGFloat = 0
        var height: CGFloat = 0

        // Dock-style row: the icon size that fits every tile, plus half-tile gaps for dividers, across the screen.
        let gapCount = dividers.filter { $0 > 0 && $0 < tiles.count }.count
        let fitted = Self.dockIconSide(count: tiles.count, gaps: gapCount, area: area)
        if dockStyle && !thumbnails && fitted >= 36 {
            let side = fitted
            tile = CGSize(width: side, height: side)
            let gap = (side * Self.gapRatio).rounded(), rowSpacing = (side * Self.rowSpacingRatio).rounded()
            columns = tiles.count
            height = side + edge * 2
            var x = edge
            for i in tiles.indices {
                if i > 0 {
                    x += rowSpacing
                    if dividers.contains(i) {
                        dividerXs.append(x + gap / 2 - rowSpacing / 2)
                        x += gap
                    }
                }
                frames.append(NSRect(x: x, y: edge, width: side, height: side))
                x += side
            }
            width = x + edge
        } else {
            // Pick the largest tile size that fits everything on screen.
            for size in sizes {
                tile = size
                let maxCols = max(1, Int((area.width * 0.92 - edge * 2 + spacing) / (size.width + spacing)))
                columns = min(tiles.count, maxCols)
                let rows = Int(ceil(Double(tiles.count) / Double(columns)))
                height = CGFloat(rows) * (size.height + spacing) - spacing + edge * 2
                if height <= area.height * 0.9 { break }
            }
            width = CGFloat(columns) * (tile.width + spacing) - spacing + edge * 2
            for i in tiles.indices {
                let x = edge + CGFloat(i % columns) * (tile.width + spacing)
                let y = height - edge - tile.height - CGFloat(i / columns) * (tile.height + spacing)
                frames.append(NSRect(x: x, y: y, width: tile.width, height: tile.height))
            }
        }

        var frame = NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        if case .below(let top) = placement {
            frame.origin = NSPoint(x: min(max(top.x - width / 2, area.minX), area.maxX - width),
                                   y: max(top.y - height, area.minY))
        }
        setFrame(frame, display: false)
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        border.frame = content.bounds
        invalidateShadow()


        for x in dividerXs {
            let line = DividerLine(frame: NSRect(x: x - 0.5, y: edge + tile.height * 0.1, width: 1, height: tile.height * 0.8))
            content.addSubview(line)
            decorations.append(line)
        }

        for (i, t) in tiles.enumerated() {
            let item = SwitcherItemView(frame: frames[i], tile: t, index: i, thumbnail: thumbnails)
            // Hover drives two independent things: selection, and (icon view only) a tooltip with the full title when
            // it says more than the name bubble (a window's title, a folder's path).
            item.onHover = { [weak self] idx in
                guard let self, NSEvent.mouseLocation != self.mouseAtShow else { return } // ignore until the mouse actually moves
                if !self.items[idx].isSelected { self.onHover?(idx) }
                if !thumbnails && t.title != t.name { self.scheduleTooltip(for: idx) }
            }
            item.onHoverEnd = { [weak self] idx in
                if self?.tooltipIndex == idx { self?.hideTooltip() }
            }
            item.onClick = { [weak self] idx in self?.onClick?(idx) }
            item.onRightClick = { [weak self] idx, event in
                self?.hideTooltip()
                self?.onRightClick?(idx, event)
            }
            content.addSubview(item)
            items.append(item)
        }

        content.addSubview(border, positioned: .above, relativeTo: nil)
        alphaValue = 1
        orderFrontRegardless()
        setSelected(selected)
    }

    func setSelected(_ index: Int) {
        for (i, item) in items.enumerated() { item.isSelected = i == index }
        guard !showsThumbnails, items.indices.contains(index) else { return }
        showNameBubble(for: index)
    }

    private func showNameBubble(for index: Int) {
        guard isVisible else { return }
        let tile = items[index].frame
        // Above the panel for the top row, like the Dock; lower rows get it just above their icon.
        let topRow = tile.maxY >= content.bounds.maxY - padding
        let y = topRow ? frame.maxY + 6 : frame.minY + tile.maxY + 2
        nameBubble.show(tilesShown[index].name, centeredAbove: NSPoint(x: frame.minX + tile.midX, y: y),
                        appearance: contentAppearance)
        if nameBubble.parent == nil { addChildWindow(nameBubble, ordered: .above) }
    }

    /// Shows the hovered window's title after a short pause, like a tooltip.
    private func scheduleTooltip(for index: Int) {
        guard tooltipIndex != index, tilesShown.indices.contains(index) else { return }
        hideTooltip()
        tooltipIndex = index
        let title = tilesShown[index].title
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible else { return }
            self.tooltip.show(title, near: NSEvent.mouseLocation, appearance: self.contentAppearance)
            self.addChildWindow(self.tooltip, ordered: .above)
        }
        pendingTooltip = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func hideTooltip() {
        pendingTooltip?.cancel()
        pendingTooltip = nil
        tooltipIndex = nil
        if tooltip.parent != nil { removeChildWindow(tooltip) }
        tooltip.orderOut(nil)
    }

    func setThumbnail(_ image: CGImage, for id: CGWindowID) {
        for item in items where item.windowID == id { item.setThumbnail(image) }
    }

    /// Where tile `index` is on screen.
    func tileScreenFrame(_ index: Int) -> NSRect? {
        guard items.indices.contains(index) else { return nil }
        return items[index].frame.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    func dismiss() {
        hideTooltip()
        if nameBubble.parent != nil { removeChildWindow(nameBubble) }
        nameBubble.orderOut(nil)
        orderOut(nil)
        items.forEach { $0.removeFromSuperview() }
        items = []
        decorations.forEach { $0.removeFromSuperview() }
        decorations = []
        tilesShown = []
    }
}

@MainActor
final class SwitcherItemView: NSView {
    static let headerHeight: CGFloat = 28

    var onHover: ((Int) -> Void)?
    var onHoverEnd: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onRightClick: ((Int, NSEvent) -> Void)?
    var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
    let windowID: CGWindowID?

    private let index: Int
    private let showsThumbnail: Bool
    private let appIcon: NSImage
    private let iconView = NSImageView()
    private let imageView = NSImageView()
    private let inset: CGFloat = 8

    init(frame: NSRect, tile: SwitcherTile, index: Int, thumbnail: Bool) {
        self.index = index
        self.windowID = tile.windowID
        self.showsThumbnail = thumbnail
        self.appIcon = tile.icon
        super.init(frame: frame)

        let badgeSize: CGFloat = 14
        guard thumbnail else {
            // Icon only; the selected window's title is shown below it by the panel.
            let inset = (frame.width * 0.08).rounded()
            iconView.image = appIcon
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.frame = bounds.insetBy(dx: inset, dy: inset)
            addSubview(iconView)
            if tile.isMinimized || tile.isAppHidden {
                addSubview(StateBadge(frame: NSRect(x: iconView.frame.maxX - badgeSize - 2, y: iconView.frame.minY + 2,
                                                    width: badgeSize, height: badgeSize),
                                      minimized: tile.isMinimized, hidden: tile.isAppHidden))
            }
            if tile.isRunning {
                // Like the Dock: a small dot just under the icon.
                let side: CGFloat = 5
                addSubview(RunningDot(frame: NSRect(x: bounds.midX - side / 2, y: max(1, iconView.frame.minY / 2 - side / 2),
                                                    width: side, height: side)))
            }
            return
        }

        // Header row (small app icon + window title) with the snapshot underneath.
        let h = Self.headerHeight
        let iconSize: CGFloat = 18
        let headerMidY = frame.height - inset / 2 - h / 2
        iconView.image = appIcon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: inset + 2, y: headerMidY - iconSize / 2, width: iconSize, height: iconSize)
        addSubview(iconView)

        let label = NSTextField(labelWithString: tile.title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        let labelX = iconView.frame.maxX + 6
        var labelRight = frame.width - inset
        if tile.isMinimized || tile.isAppHidden {
            labelRight -= badgeSize + 6
            addSubview(StateBadge(frame: NSRect(x: frame.width - inset - 2 - badgeSize, y: headerMidY - badgeSize / 2,
                                                width: badgeSize, height: badgeSize),
                                  minimized: tile.isMinimized, hidden: tile.isAppHidden))
        }
        label.frame = NSRect(x: labelX, y: headerMidY - 9, width: labelRight - labelX, height: 18)
        addSubview(label)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
        if let id = tile.windowID, let image = Thumbnails.shared.cached(id) { setThumbnail(image) } else { showPlaceholder() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var thumbnailArea: NSRect {
        NSRect(x: inset, y: inset, width: bounds.width - inset * 2, height: bounds.height - inset - inset / 2 - Self.headerHeight)
    }

    func setThumbnail(_ image: CGImage) {
        guard showsThumbnail else { return }
        imageView.image = NSImage(cgImage: image, size: .zero)
        imageView.frame = thumbnailArea
    }

    /// Shown until a snapshot arrives, or for windows that can't be captured (no permission, never seen on screen).
    private func showPlaceholder() {
        let area = thumbnailArea
        let side = min(64, area.width, area.height)
        imageView.image = appIcon
        imageView.frame = NSRect(x: area.midX - side / 2, y: area.midY - side / 2, width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        // Native-style highlight: a darker rounded square behind the selection, no border.
        let rect: NSRect
        let radius: CGFloat
        if showsThumbnail {
            rect = bounds
            radius = 12
        } else {
            // Hug the icon's visible squircle, which is about 80% of the icon image (the rest is transparent padding).
            let side = iconView.frame.width
            rect = iconView.frame.insetBy(dx: side * 0.02, dy: side * 0.02)
            radius = rect.width * 0.27
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor.white.withAlphaComponent(0.25) : NSColor.black.withAlphaComponent(0.35)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHover?(index) }
    override func mouseMoved(with event: NSEvent) { onHover?(index) }
    override func mouseExited(with event: NSEvent) { onHoverEnd?(index) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(index) }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(index, event) }
}

/// The Dock's section divider.
final class DividerLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.3).setFill()
        bounds.fill()
    }
}

/// The Dock's running-app indicator.
final class RunningDot: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.8).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Yellow badge for a window's state: a ring means its app is hidden, a centered dot means the window is minimized.
/// Both together show the ring around the same dot.
final class StateBadge: NSView {
    private let minimized: Bool
    private let appHidden: Bool

    private static let fill = NSColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1)
    private static let outline = NSColor(srgbRed: 0.87, green: 0.6, blue: 0.1, alpha: 1)

    init(frame: NSRect, minimized: Bool, hidden: Bool) {
        self.minimized = minimized
        self.appHidden = hidden
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if appHidden {
            let ringWidth = bounds.width * 0.15
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
            ring.lineWidth = ringWidth
            Self.fill.setStroke()
            ring.stroke()
        }
        if minimized {
            let side = bounds.width * 0.45
            let dot = NSBezierPath(ovalIn: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side))
            Self.fill.setFill()
            dot.fill()
            Self.outline.setStroke()
            dot.lineWidth = 0.75
            dot.stroke()
        }
    }
}

/// A rounded-rect mask for visual-effect views; a layer corner radius doesn't clip behind-window blur.
@MainActor
func roundedMaskImage(radius: CGFloat) -> NSImage {
    let side = radius * 2 + 1
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}

/// A tooltip look-alike. Real tooltips don't appear in the switcher, because it's a panel that never becomes active.
@MainActor
final class TooltipWindow: OverlayPanel {
    private let label = NSTextField(labelWithString: "")

    override init() {
        super.init()
        ignoresMouseEvents = true

        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.maskImage = roundedMaskImage(radius: 5)
        contentView = background

        label.font = .toolTipsFont(ofSize: 0)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        background.addSubview(label)
    }

    /// Shows `text` just below and right of `point` (screen coordinates), kept on screen.
    func show(_ text: String, near point: NSPoint, appearance: NSAppearance) {
        let size = prepare(text, appearance: appearance)
        place(NSPoint(x: point.x + 4, y: point.y - 22 - size.height), size: size, screenOf: point)
    }

    /// Shows `text` centered horizontally on `point` with its bottom edge there, like the Dock's name labels.
    func show(_ text: String, centeredAbove point: NSPoint, appearance: NSAppearance) {
        let size = prepare(text, appearance: appearance)
        place(NSPoint(x: point.x - size.width / 2, y: point.y), size: size, screenOf: point)
    }

    private func prepare(_ text: String, appearance: NSAppearance) -> NSSize {
        contentAppearance = appearance
        label.stringValue = text
        // intrinsicContentSize comes out a few points narrower than the text needs, which truncates every title.
        let cellSize = label.cell?.cellSize ?? label.intrinsicContentSize
        let textSize = NSSize(width: ceil(cellSize.width), height: ceil(cellSize.height))
        label.frame = NSRect(x: 7, y: 3, width: min(textSize.width, 586), height: textSize.height)
        return NSSize(width: min(textSize.width + 14, 600), height: textSize.height + 6)
    }

    /// Puts the window at `origin`, kept on the screen containing `point`.
    private func place(_ origin: NSPoint, size: NSSize, screenOf point: NSPoint) {
        let screen = NSScreen.containing(point).visibleFrame
        var origin = origin
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        origin.y = min(max(origin.y, screen.minY + 4), screen.maxY - size.height - 4)
        setFrame(NSRect(origin: origin, size: size), display: false)
        orderFrontRegardless()
    }
}
