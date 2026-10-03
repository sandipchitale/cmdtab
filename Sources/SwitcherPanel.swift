import AppKit

/// Where a panel goes on its screen.
enum PanelPlacement {
    case centered
    /// Hanging below a point (screen coordinates), centered on it: the window previews.
    case below(topCenter: NSPoint)
}

/// Where the tiles go: a grid of the largest size that fits, or a Dock-style row whose icons shrink to fit the width.
struct TileLayout {
    /// The margin around thumbnail tiles, which carry their own title row.
    static let thumbnailPadding: CGFloat = 20
    /// The margin around icon tiles.
    static let iconPadding: CGFloat = 14
    private static let spacing: CGFloat = 12
    /// In the Dock-style row: the space between icons, and the extra gap for a divider, per icon side.
    private static let rowSpacingRatio: CGFloat = 0.1, gapRatio: CGFloat = 0.5

    /// Each tile's frame, in panel coordinates.
    private(set) var frames: [NSRect] = []
    /// Where the Dock-style row's dividers go (x, in panel coordinates).
    private(set) var dividerXs: [CGFloat] = []
    private(set) var tile = CGSize.zero
    private(set) var columns = 1
    private(set) var size = CGSize.zero
    /// The margin on all four sides.
    let edge: CGFloat

    /// The icon size of a Dock-style row of `count` items with `gaps` dividers across `area`, at most 120.
    static func dockIconSide(count: Int, gaps: Int, area: NSRect) -> CGFloat {
        let n = CGFloat(max(count, 1))
        let fitted = (area.width * 0.92 - iconPadding * 2) / (n + rowSpacingRatio * (n - 1) + gapRatio * CGFloat(gaps))
        return min(fitted.rounded(.down), 120)
    }

    init(count: Int, area: NSRect, thumbnails: Bool, dockStyle: Bool, dividers: Set<Int>,
         iconsLikeDock: (count: Int, gaps: Int)?, maxTileWidth: CGFloat?) {
        edge = thumbnails ? Self.thumbnailPadding : Self.iconPadding
        let gapCount = dividers.filter { $0 > 0 && $0 < count }.count
        let fitted = Self.dockIconSide(count: count, gaps: gapCount, area: area)
        if dockStyle && !thumbnails && fitted >= 36 {
            layOutRow(count: count, side: fitted, dividers: dividers)
        } else {
            layOutGrid(count: count, area: area,
                       sizes: Self.candidateSizes(thumbnails: thumbnails, area: area, iconsLikeDock: iconsLikeDock,
                                                  maxTileWidth: maxTileWidth))
        }
    }

    /// Tile sizes to try, largest first.
    private static func candidateSizes(thumbnails: Bool, area: NSRect, iconsLikeDock: (count: Int, gaps: Int)?,
                                       maxTileWidth: CGFloat?) -> [CGSize] {
        if thumbnails {
            var widths: [CGFloat] = [320, 280, 240, 200, 170, 140]
            if let maxTileWidth {
                // At least the smallest size, even if it's wider than asked.
                let fitting = widths.filter { $0 <= maxTileWidth }
                widths = fitting.isEmpty ? [widths[widths.count - 1]] : fitting
            }
            return widths.map { CGSize(width: $0, height: ($0 * 0.62 + SwitcherItemView.headerHeight).rounded()) }
        }
        var sides: [CGFloat] = [120, 104, 88, 76, 64]
        if let dock = iconsLikeDock {
            // The Dock's icon size first, then smaller sizes in case that many windows don't fit.
            let side = max(dockIconSide(count: dock.count, gaps: dock.gaps, area: area), 36)
            sides = [side] + sides.filter { $0 < side }
        }
        return sides.map { CGSize(width: $0, height: $0) }
    }

    /// One row of `side`-sized icons, with half-icon gaps (and a line) in front of the `dividers`.
    private mutating func layOutRow(count: Int, side: CGFloat, dividers: Set<Int>) {
        tile = CGSize(width: side, height: side)
        let gap = (side * Self.gapRatio).rounded(), rowSpacing = (side * Self.rowSpacingRatio).rounded()
        columns = count
        var x = edge
        for i in 0..<count {
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
        size = CGSize(width: x + edge, height: side + edge * 2)
    }

    /// A grid of the largest of `sizes` that fits everything on screen.
    private mutating func layOutGrid(count: Int, area: NSRect, sizes: [CGSize]) {
        let spacing = Self.spacing
        var height: CGFloat = 0
        for size in sizes {
            tile = size
            let maxCols = max(1, Int((area.width * 0.92 - edge * 2 + spacing) / (size.width + spacing)))
            columns = min(count, maxCols)
            let rows = Int(ceil(Double(count) / Double(columns)))
            height = CGFloat(rows) * (size.height + spacing) - spacing + edge * 2
            if height <= area.height * 0.9 { break }
        }
        size = CGSize(width: CGFloat(columns) * (tile.width + spacing) - spacing + edge * 2, height: height)
        for i in 0..<count {
            let x = edge + CGFloat(i % columns) * (tile.width + spacing)
            let y = height - edge - tile.height - CGFloat(i / columns) * (tile.height + spacing)
            frames.append(NSRect(x: x, y: y, width: tile.width, height: tile.height))
        }
    }
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

    private let cornerRadius: CGFloat = 26

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
        clear()
        tilesShown = tiles
        showsThumbnails = thumbnails
        mouseAtShow = NSEvent.mouseLocation
        applyAppearance()

        let area = screen.visibleFrame
        let layout = TileLayout(count: tiles.count, area: area, thumbnails: thumbnails, dockStyle: dockStyle,
                                dividers: dividers, iconsLikeDock: iconsLikeDock, maxTileWidth: maxTileWidth)
        columns = layout.columns
        let (width, height) = (layout.size.width, layout.size.height)
        var frame = NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        if case .below(let top) = placement {
            frame.origin = NSPoint(x: min(max(top.x - width / 2, area.minX), area.maxX - width),
                                   y: max(top.y - height, area.minY))
        }
        setFrame(frame, display: false)
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        border.frame = content.bounds
        invalidateShadow()

        for x in layout.dividerXs {
            let line = DividerLine(frame: NSRect(x: x - 0.5, y: layout.edge + layout.tile.height * 0.1,
                                                 width: 1, height: layout.tile.height * 0.8))
            content.addSubview(line)
            decorations.append(line)
        }
        for (i, tile) in tiles.enumerated() {
            let item = makeItem(tile, index: i, frame: layout.frames[i])
            content.addSubview(item)
            items.append(item)
        }

        content.addSubview(border, positioned: .above, relativeTo: nil)
        alphaValue = 1
        // Ordered front before selecting: the name bubble only shows on a visible panel.
        orderFrontRegardless()
        setSelected(selected)
    }

    /// The content's appearance, per the Appearance setting, and the border and tint colors that go with it.
    private func applyAppearance() {
        contentAppearance = .forPanels
        border.layer?.borderColor = (contentAppearance.isDark ? NSColor.white.withAlphaComponent(0.3)
                                                              : NSColor.black.withAlphaComponent(0.25)).cgColor
        if let tint {
            contentAppearance.performAsCurrentDrawingAppearance {
                tint.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55).cgColor
            }
        }
    }

    private func makeItem(_ tile: SwitcherTile, index: Int, frame: NSRect) -> SwitcherItemView {
        let thumbnails = showsThumbnails
        let item = SwitcherItemView(frame: frame, tile: tile, index: index, thumbnail: thumbnails)
        // Hover drives two independent things: selection, and (icon view only) a tooltip with the full title when
        // it says more than the name bubble (a window's title, a folder's path).
        item.onHover = { [weak self] idx in
            guard let self, NSEvent.mouseLocation != self.mouseAtShow else { return } // ignore until the mouse actually moves
            if !self.items[idx].isSelected { self.onHover?(idx) }
            if !thumbnails && tile.title != tile.name { self.scheduleTooltip(for: idx) }
        }
        item.onHoverEnd = { [weak self] idx in
            if self?.tooltipIndex == idx { self?.hideTooltip() }
        }
        item.onClick = { [weak self] idx in self?.onClick?(idx) }
        item.onRightClick = { [weak self] idx, event in
            self?.hideTooltip()
            self?.onRightClick?(idx, event)
        }
        return item
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
        let topRow = tile.maxY >= content.bounds.maxY - TileLayout.thumbnailPadding
        let y = topRow ? frame.maxY + 6 : frame.minY + tile.maxY + 2
        nameBubble.show(tilesShown[index].name, centeredAbove: NSPoint(x: frame.minX + tile.midX, y: y),
                        appearance: contentAppearance)
        attach(nameBubble)
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
            self.attach(self.tooltip)
        }
        pendingTooltip = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func hideTooltip() {
        pendingTooltip?.cancel()
        pendingTooltip = nil
        tooltipIndex = nil
        detach(tooltip)
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
        detach(nameBubble)
        orderOut(nil)
        clear()
    }

    /// Removes the tiles (and the tooltip that may belong to one of them).
    private func clear() {
        hideTooltip()
        items.forEach { $0.removeFromSuperview() }
        items = []
        decorations.forEach { $0.removeFromSuperview() }
        decorations = []
        tilesShown = []
    }
}
