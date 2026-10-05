import AppKit

/// Where a panel goes on its screen.
enum PanelPlacement {
    case centered
    /// Hanging below a point (screen coordinates), centered on it: the window previews.
    case below(topCenter: NSPoint)
    /// Centered on a point (screen coordinates), kept on screen: a window-preview card in the arc around a ring.
    case at(center: NSPoint)
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
    /// In a crowded row, a divider's gap is narrower, like the real Dock's.
    private static let tightGapRatio: CGFloat = 0.45
    /// The smallest icons the roomy row uses; a crowded row tightens its spacing before going below this.
    private static let roomyRowSide: CGFloat = 36

    /// Each tile's frame, in panel coordinates.
    private(set) var frames: [NSRect] = []
    /// Where the Dock-style row's dividers go (x, in panel coordinates).
    private(set) var dividerXs: [CGFloat] = []
    private(set) var tile = CGSize.zero
    private(set) var columns = 1
    private(set) var size = CGSize.zero
    /// The margin on all four sides.
    let edge: CGFloat
    /// The ring layout's geometry; nil for a grid or row.
    private(set) var ring: RingGeometry?

    /// The icon size of a Dock-style row of `count` items with `gaps` dividers across `area`, at most 120.
    static func dockIconSide(count: Int, gaps: Int, area: NSRect) -> CGFloat {
        let n = CGFloat(max(count, 1))
        let fitted = (area.width * 0.92 - iconPadding * 2) / (n + rowSpacingRatio * (n - 1) + gapRatio * CGFloat(gaps))
        return min(fitted.rounded(.down), 120)
    }

    /// The icon side, the space between icons and a divider's gap for a Dock-style row of `count` items with `gaps`
    /// dividers across `area`, or nil if it can't be one row. Roomy while the icons can be 36 or more. When it's
    /// crowded, the row takes the whole width and its spacing tightens, like the real Dock's, keeping the icons at 36;
    /// only then do they shrink, down to `smallestSide`.
    static func dockRow(count: Int, gaps: Int, area: NSRect, smallestSide: CGFloat) -> (side: CGFloat, spacing: CGFloat, gap: CGFloat)? {
        let roomy = dockIconSide(count: count, gaps: gaps, area: area)
        if roomy >= roomyRowSide { return (roomy, (roomy * rowSpacingRatio).rounded(), (roomy * gapRatio).rounded()) }
        let n = CGFloat(max(count, 1)), g = CGFloat(gaps), width = area.width - iconPadding * 2
        // Tighter spacing first: as much of the usual space between icons as still fits beside 36-point icons.
        let side = roomyRowSide, gap = (side * tightGapRatio).rounded()
        let spare = width - n * side - g * gap
        if spare >= 0 {
            let spacing = n > 1 ? min((spare / (n - 1)).rounded(.down), (side * rowSpacingRatio).rounded()) : 0
            return (side, spacing, gap)
        }
        // Last resort: smaller icons, side by side, as small as the real Dock draws its own.
        let shrunk = (width / (n + tightGapRatio * g)).rounded(.down)
        return shrunk >= smallestSide ? (shrunk, 0, (shrunk * tightGapRatio).rounded()) : nil
    }

    /// `sizingCount` (at least `count`) sizes the tiles for that many, so a search showing only some of them keeps
    /// them the size they have with all of them shown; likewise `iconsLikeDock` for a Dock-style row. A crowded
    /// Dock-style row tightens its spacing, then shrinks its icons down to `smallestRowSide`, before it wraps into a grid.
    init(count: Int, area: NSRect, thumbnails: Bool, dockStyle: Bool, dividers: Set<Int>,
         iconsLikeDock: (count: Int, gaps: Int)?, maxTileWidth: CGFloat?, sizingCount: Int? = nil,
         smallestRowSide: CGFloat = 36) {
        edge = thumbnails ? Self.thumbnailPadding : Self.iconPadding
        let gapCount = dividers.filter { $0 > 0 && $0 < count }.count
        let row = dockStyle && !thumbnails
            ? Self.dockRow(count: iconsLikeDock?.count ?? count, gaps: iconsLikeDock?.gaps ?? gapCount, area: area,
                           smallestSide: smallestRowSide)
            : nil
        if let row {
            layOutRow(count: count, side: row.side, spacing: row.spacing, gap: row.gap, dividers: dividers)
        } else {
            layOutGrid(count: count, sizingCount: max(sizingCount ?? count, count), area: area,
                       sizes: Self.candidateSizes(thumbnails: thumbnails, area: area, iconsLikeDock: iconsLikeDock,
                                                  maxTileWidth: maxTileWidth))
        }
    }

    /// Tiles around a ring, clockwise from 12 o'clock: the largest tile size that fits, on the smallest ring that keeps
    /// neighbors apart and leaves room in the middle for the title, up to 56% of `area`.
    init(ringOf count: Int, area: NSRect, thumbnails: Bool) {
        edge = thumbnails ? Self.thumbnailPadding : Self.iconPadding
        let side = min(area.width, area.height)
        let maxOuter = (side * 0.28).rounded(), minHub = (side * 0.13).rounded()
        // Smaller than the grid's largest tiles, so the band stays slim.
        let sizes: [CGSize] = thumbnails
            ? [200, 180, 160, 140, 120].map { CGSize(width: $0, height: ($0 * 0.62 + SwitcherItemView.headerHeight).rounded()) }
            : [88, 80, 72, 64, 56, 48, 40, 34].map { CGSize(width: $0, height: $0) }
        var outer = maxOuter, reach: CGFloat = 0
        for size in sizes {
            tile = size
            // How far the tiles reach toward and away from the center, which sets the band's width: a thumbnail's
            // extent in its own direction (wide at 12 and 6 o'clock, tall at 3 and 9); an icon's visible squircle,
            // whose corners are transparent.
            reach = thumbnails
                ? (0..<max(count, 1)).map { size.extent(toward: RingGeometry.angle($0, of: count)) }.max() ?? 0
                : size.width * 0.58
            // Neighbors' centers are a chord apart, which must clear the tiles at any angle.
            let gap = thumbnails ? hypot(size.width, size.height) + 8 : size.width * 1.12
            let spread = count > 1 ? gap / (2 * sin(.pi / CGFloat(count))) : 0
            let radius = max(spread, minHub + 8 + reach)
            outer = min((radius + reach + edge).rounded(.up), maxOuter)
            if radius + reach + edge <= maxOuter { break }
        }
        let radius = outer - edge - reach
        let geometry = RingGeometry(center: NSPoint(x: outer, y: outer), outerRadius: outer,
                                    hubRadius: max(radius - reach - 8, 0), count: count)
        ring = geometry
        columns = count
        size = CGSize(width: outer * 2, height: outer * 2)
        for i in 0..<count {
            let angle = geometry.angle(i)
            frames.append(NSRect(x: (outer + radius * cos(angle) - tile.width / 2).rounded(),
                                 y: (outer + radius * sin(angle) - tile.height / 2).rounded(),
                                 width: tile.width, height: tile.height))
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

    /// One row of `side`-sized icons, `rowSpacing` apart, with `gap` (and a line) in front of the `dividers`.
    private mutating func layOutRow(count: Int, side: CGFloat, spacing rowSpacing: CGFloat, gap: CGFloat, dividers: Set<Int>) {
        tile = CGSize(width: side, height: side)
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

    /// A grid of `count` tiles, of the largest of `sizes` with which `sizingCount` tiles fit on screen.
    private mutating func layOutGrid(count: Int, sizingCount: Int, area: NSRect, sizes: [CGSize]) {
        let spacing = Self.spacing
        func columnCount(_ count: Int, of size: CGSize) -> Int {
            min(count, max(1, Int((area.width * 0.92 - edge * 2 + spacing) / (size.width + spacing))))
        }
        func gridHeight(_ count: Int, of size: CGSize) -> CGFloat {
            let rows = Int(ceil(Double(count) / Double(columnCount(count, of: size))))
            return CGFloat(rows) * (size.height + spacing) - spacing + edge * 2
        }
        for size in sizes {
            tile = size
            if gridHeight(sizingCount, of: size) <= area.height * 0.9 { break }
        }
        columns = columnCount(count, of: tile)
        let height = gridHeight(count, of: tile)
        size = CGSize(width: CGFloat(columns) * (tile.width + spacing) - spacing + edge * 2, height: height)
        for i in 0..<count {
            let x = edge + CGFloat(i % columns) * (tile.width + spacing)
            let y = height - edge - tile.height - CGFloat(i / columns) * (tile.height + spacing)
            frames.append(NSRect(x: x, y: y, width: tile.width, height: tile.height))
        }
    }
}

/// Tiles around a ring: their centers sit on a circle around the panel's center, clockwise from 12 o'clock, like
/// WindowRing's. Panel coordinates (y up).
struct RingGeometry {
    let center: NSPoint
    /// The disc's radius.
    let outerRadius: CGFloat
    /// The see-through middle, inside the tiles: the selected tile's title goes there.
    let hubRadius: CGFloat
    let count: Int

    var step: CGFloat { Self.step(count) }

    /// The angle between neighboring tiles of a ring of `count`.
    static func step(_ count: Int) -> CGFloat { 2 * .pi / CGFloat(max(count, 1)) }

    /// The direction of tile `index` of `count` from the center, in radians (y up): 12 o'clock, then clockwise.
    static func angle(_ index: Int, of count: Int) -> CGFloat { .pi / 2 - CGFloat(index) * step(count) }

    /// Tile `index`'s direction from the center, in radians (y up).
    func angle(_ index: Int) -> CGFloat { Self.angle(index, of: count) }

    /// The tile in the direction of `point`, or nil in the hub or outside the disc.
    func index(at point: NSPoint) -> Int? {
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard count > 0, distance > hubRadius, distance <= outerRadius else { return nil }
        // Clockwise from 12 o'clock, reduced into [0, 2π) before rounding: atan2 runs from -π to π, and an unreduced
        // difference makes a whole arc pick the wrong tile (the bug WindowRing's README describes).
        var turn = (.pi / 2 - atan2(dy, dx)).truncatingRemainder(dividingBy: 2 * .pi)
        if turn < 0 { turn += 2 * .pi }
        return Int((turn / step).rounded()) % count
    }
}

extension CGSize {
    /// How far a rectangle of this size reaches from its center in direction `angle` (radians): half its width
    /// sideways, half its height up or down, and in between at an angle.
    func extent(toward angle: CGFloat) -> CGFloat { width / 2 * abs(cos(angle)) + height / 2 * abs(sin(angle)) }
}

/// The floating Alt+Tab-style grid.
@MainActor
final class SwitcherPanel: OverlayPanel {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onRightClick: ((Int, NSEvent) -> Void)?
    /// A tile's hover button (close, minimize, fill) was pressed.
    var onWindowButton: ((Int, WindowButton) -> Void)?
    private(set) var columns = 1

    /// Holds the tiles; sits inside the glass (or the fallback blur).
    private let content = NSView()
    /// Only in the pre-Liquid Glass fallback: tones down the blur's see-through look.
    private var tint: NSView?
    /// Liquid Glass, where there is one; it takes the window switcher's tint.
    private var glass: AnyObject?
    /// The window switcher is tinted with the Accent color so it can't be mistaken for the Dock; the Dock stays
    /// neutral.
    private var tinted = false
    /// The window switcher's tint wash over the whole background, behind the tiles.
    private let wash = NSView()
    /// A hairline in the opposite tone of the panel, so it doesn't melt into a matching light or dark background.
    private let border = NSView()
    private let tooltip = TooltipWindow()
    /// In icon view, the selected item's name floats in a bubble above its icon, like the Dock's.
    private let nameBubble = TooltipWindow()
    /// Why a key did nothing, for a moment, where the selected item's name goes.
    private let notice = NoticeBubble()
    private var noticeFade: DispatchWorkItem?
    /// Bumped as each notice comes and goes, so the fade of one that's gone can't take away the next.
    private var noticeCount = 0
    private var pendingTooltip: DispatchWorkItem?
    private var tooltipIndex: Int?
    private var items: [SwitcherItemView] = []
    /// Dividers drawn between tiles in the single-row layout.
    private var decorations: [NSView] = []
    private var tilesShown: [SwitcherTile] = []
    private var mouseAtShow = NSPoint.zero
    private var showsThumbnails = false
    /// The Dock's tiles carry the digit of their Fn+number key (the first ten), shown while Fn is held.
    private var numbersTiles = false
    /// The ring layout (R), if the tiles are laid out around one.
    private(set) var ring: RingGeometry?
    /// The ring's band: the selected tile's wedge, and a hairline around the hub.
    private let ringBand = RingBandView()
    /// The selected tile's name (and title) in the ring's see-through middle.
    private let hubTitle = HubTitle()
    /// Only in the pre-Liquid Glass fallback: the blur, which a mask image rounds.
    private var blur: NSVisualEffectView?

    private static let cornerRadius: CGFloat = 26

    override init() {
        super.init()
        isFloatingPanel = true

        if #available(macOS 26.0, *) {
            // Liquid Glass, as used by the system Cmd+Tab switcher.
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = content
            contentView = glass
            self.glass = glass
            // The glass draws its own edge; the window shadow adds a dark outline that bunches up at the corners.
            hasShadow = false
        } else {
            let background = NSVisualEffectView()
            background.material = .popover
            background.blendingMode = .behindWindow
            background.state = .active
            // A layer corner radius doesn't clip behind-window blur (square corners leak out); a mask image does,
            // and the window shadow follows it.
            background.maskImage = roundedMaskImage(radius: Self.cornerRadius)
            contentView = background
            blur = background

            // Its color is resolved per appearance in show().
            let tint = NSView()
            tint.wantsLayer = true
            tint.layer?.cornerRadius = Self.cornerRadius
            tint.autoresizingMask = [.width, .height]
            background.addSubview(tint)
            self.tint = tint
            content.autoresizingMask = [.width, .height]
            background.addSubview(content)
        }

        wash.wantsLayer = true
        wash.layer?.cornerRadius = Self.cornerRadius
        wash.autoresizingMask = [.width, .height]
        content.addSubview(wash)

        ringBand.autoresizingMask = [.width, .height]
        // The same guards as a tile's hover: not until the mouse moves, and only for a change, since every selection
        // change redraws the window previews.
        ringBand.onHover = { [weak self] i in
            guard let self, NSEvent.mouseLocation != self.mouseAtShow, self.items.indices.contains(i),
                  !self.items[i].isSelected else { return }
            self.onHover?(i)
        }
        ringBand.onClick = { [weak self] i in self?.onClick?(i) }
        ringBand.onRightClick = { [weak self] i, event in self?.onRightClick?(i, event) }
        content.addSubview(ringBand)

        border.wantsLayer = true
        border.layer?.cornerRadius = Self.cornerRadius
        border.layer?.borderWidth = 1
        border.autoresizingMask = [.width, .height]
        content.addSubview(border)
    }

    /// Lays out `tiles` as a grid, or (with `dockStyle`) like the Dock: one row whose icons shrink to fit the width,
    /// with section dividers in front of the tiles listed in `dividers`, and the selected name above its icon.
    /// `iconsLikeDock` (count and dividers of the Dock) sizes icon tiles the same as the Dock-style row would be.
    /// `placement` and `maxTileWidth` let the Dock hang a small strip of window previews under an icon. `sizingCount`
    /// sizes the tiles for that many (a search shows only some of them). A Dock-style row shrinks down to
    /// `smallestRowSide` before it wraps.
    func show(tiles: [SwitcherTile], selected: Int, on screen: NSScreen, thumbnails: Bool,
              dockStyle: Bool = false, dividers: Set<Int> = [], iconsLikeDock: (count: Int, gaps: Int)? = nil,
              ring: Bool = false, placement: PanelPlacement = .centered, maxTileWidth: CGFloat? = nil,
              tinted: Bool = false, sizingCount: Int? = nil, smallestRowSide: CGFloat = 36) {
        clear()
        self.tinted = tinted
        tilesShown = tiles
        showsThumbnails = thumbnails
        numbersTiles = dockStyle
        mouseAtShow = NSEvent.mouseLocation
        applyAppearance()

        let area = screen.visibleFrame
        let layout = ring
            ? TileLayout(ringOf: tiles.count, area: area, thumbnails: thumbnails)
            : TileLayout(count: tiles.count, area: area, thumbnails: thumbnails, dockStyle: dockStyle,
                         dividers: dividers, iconsLikeDock: iconsLikeDock, maxTileWidth: maxTileWidth,
                         sizingCount: sizingCount, smallestRowSide: smallestRowSide)
        columns = layout.columns
        // Panels are reused, so everything the ring changes is set either way.
        self.ring = layout.ring
        setCornerRadius(layout.ring?.outerRadius ?? Self.cornerRadius)
        ringBand.geometry = layout.ring
        ringBand.isHidden = layout.ring == nil
        detach(hubTitle)
        let (width, height) = (layout.size.width, layout.size.height)
        /// `origin`, moved as little as needed to keep the panel on screen.
        func onScreen(_ origin: NSPoint) -> NSPoint {
            NSPoint(x: min(max(origin.x, area.minX), area.maxX - width), y: min(max(origin.y, area.minY), area.maxY - height))
        }
        let origin = switch placement {
        case .centered: NSPoint(x: area.midX - width / 2, y: area.midY - height / 2)
        case .below(let top): onScreen(NSPoint(x: top.x - width / 2, y: top.y - height))
        case .at(let center): onScreen(NSPoint(x: center.x - width / 2, y: center.y - height / 2))
        }
        setFrame(NSRect(origin: origin, size: layout.size), display: false)
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        border.frame = content.bounds
        wash.frame = content.bounds
        ringBand.frame = content.bounds
        setHole(layout.ring)
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
        let dark = contentAppearance.isDark
        let tint = tinted ? AccentTint(appearance: contentAppearance) : nil
        // Drawn over the glass itself, so the background reads in the tint color whatever is behind the panel.
        wash.layer?.backgroundColor = (tint?.color(.wash) ?? .clear).cgColor
        let neutralBorder = dark ? NSColor.white.withAlphaComponent(0.3) : NSColor.black.withAlphaComponent(0.25)
        border.layer?.borderColor = (tint?.color(.border) ?? neutralBorder).cgColor
        if #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView {
            glass.tintColor = tint?.color(.glass)
        }
        if let fallback = self.tint {
            contentAppearance.performAsCurrentDrawingAppearance {
                let base = NSColor.windowBackgroundColor.withAlphaComponent(0.55)
                if let color = tint?.color(.glass) {
                    // Over the neutral base: composite the tint onto it.
                    fallback.layer?.backgroundColor = (base.blended(withFraction: color.alphaComponent * 1.5, of: color.withAlphaComponent(1)) ?? base).cgColor
                } else {
                    fallback.layer?.backgroundColor = base.cgColor
                }
            }
        }
    }

    /// In the ring, cuts the middle out of the panel so it's a band around a see-through hole.
    private func setHole(_ ring: RingGeometry?) {
        let band = ring.map { ring in
            let path = CGMutablePath()
            for radius in [ring.outerRadius, ring.hubRadius] {
                path.addEllipse(in: CGRect(x: ring.center.x - radius, y: ring.center.y - radius, width: radius * 2, height: radius * 2))
            }
            return path
        }
        // The glass (or the blur) and everything on it; a layer can mask only one other, so each gets its own.
        for view in [glass as? NSView ?? blur, content] {
            view?.wantsLayer = true
            view?.layer?.mask = band.map { path in
                let mask = CAShapeLayer()
                mask.path = path
                mask.fillRule = .evenOdd
                return mask
            }
        }
    }

    /// Rounds the panel: its usual corners, or a full circle for the ring.
    private func setCornerRadius(_ radius: CGFloat) {
        if #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView { glass.cornerRadius = radius }
        blur?.maskImage = roundedMaskImage(radius: radius)
        for view in [tint, wash, border] { view?.layer?.cornerRadius = radius }
    }

    private func makeItem(_ tile: SwitcherTile, index: Int, frame: NSRect) -> SwitcherItemView {
        let thumbnails = showsThumbnails
        let item = SwitcherItemView(frame: frame, tile: tile, index: index, thumbnail: thumbnails)
        item.drawsHighlight = ring == nil
        item.setButtonsAllowed(ring == nil)
        item.mouseAtShow = mouseAtShow
        if numbersTiles && index < 10 { item.addNumberBadge(digit: (index + 1) % 10) }
        item.onWindowButton = { [weak self] idx, button in
            self?.hideTooltip()
            self?.onWindowButton?(idx, button)
        }
        // Hover drives two independent things: selection, and (icon view only) a tooltip with the full title when
        // it says more than the name bubble (a window's title, a folder's path).
        item.onHover = { [weak self] idx in
            // In the ring, the band selects by direction, tiles included; two sources could disagree at a tile's edge.
            guard let self, self.ring == nil, NSEvent.mouseLocation != self.mouseAtShow else { return } // ignore until the mouse actually moves
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
        // A notice is about the selection it was shown for.
        endNotice()
        for (i, item) in items.enumerated() { item.isSelected = i == index }
        if ring != nil {
            ringBand.selected = index
            detach(nameBubble)
            hideTooltip()
            return showHubTitle(for: index)
        }
        // Thumbnails carry their own titles; drop any bubble left from icon view (G toggles between the two).
        if showsThumbnails { return detach(nameBubble) }
        guard items.indices.contains(index) else { return }
        showNameBubble(for: index)
    }

    private func showNameBubble(for index: Int) {
        guard isVisible else { return }
        nameBubble.show(tilesShown[index].name, centeredAbove: nameAnchor(for: index), appearance: contentAppearance)
        attach(nameBubble)
    }

    /// Where tile `index`'s name goes (screen coordinates, its bottom center): above the panel for the top row, like
    /// the Dock; just above the tile for lower rows, and in a ring.
    private func nameAnchor(for index: Int) -> NSPoint {
        let tile = items[index].frame
        let topRow = ring == nil && tile.maxY >= content.bounds.maxY - TileLayout.thumbnailPadding
        return NSPoint(x: frame.minX + tile.midX, y: topRow ? frame.maxY + 6 : frame.minY + tile.maxY + 2)
    }

    /// Says why a key did nothing, in place of a beep: `text` where the selected tile's name goes, instead of the name
    /// for a couple of seconds. Then it fades away and the name comes back.
    func showNotice(_ text: String) {
        guard isVisible, let index = items.firstIndex(where: \.isSelected) ?? items.indices.first else { return }
        endNotice()
        detach(nameBubble)
        notice.show(text, centeredAbove: nameAnchor(for: index), appearance: contentAppearance)
        attach(notice)
        let count = noticeCount
        let fade = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self?.notice.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    guard let self, self.noticeCount == count else { return }
                    self.endNotice()
                    // Thumbnails carry their own names, and a ring has its title in the middle.
                    guard self.ring == nil, !self.showsThumbnails, let i = self.items.firstIndex(where: \.isSelected) else { return }
                    self.showNameBubble(for: i)
                }
            }
        }
        noticeFade = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: fade)
    }

    /// Takes the notice away at once.
    private func endNotice() {
        noticeCount += 1
        noticeFade?.cancel()
        noticeFade = nil
        detach(notice)
    }

    /// In the ring, the selected tile's name in the middle, with its title under it when that says more. Thumbnails
    /// carry their own titles.
    private func showHubTitle(for index: Int) {
        guard let ring, !showsThumbnails, isVisible, tilesShown.indices.contains(index) else { return detach(hubTitle) }
        let tile = tilesShown[index]
        hubTitle.show(name: tile.name, title: tile.title, maxWidth: ring.hubRadius * 1.2,
                      centeredOn: NSPoint(x: frame.minX + ring.center.x, y: frame.minY + ring.center.y),
                      appearance: contentAppearance)
        attach(hubTitle)
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

    func setNumbersVisible(_ visible: Bool) {
        items.forEach { $0.setNumberVisible(visible) }
    }

    /// If the tiles are in a ring: its center and outer radius on screen, and tile `index`'s direction (radians, y up),
    /// which the window previews' arc goes around.
    func ringAnchor(for index: Int) -> (center: NSPoint, radius: CGFloat, angle: CGFloat)? {
        ring.map { (NSPoint(x: frame.minX + $0.center.x, y: frame.minY + $0.center.y), $0.outerRadius, $0.angle(index)) }
    }

    /// Where tile `index` is on screen.
    func tileScreenFrame(_ index: Int) -> NSRect? {
        guard items.indices.contains(index) else { return nil }
        return items[index].frame.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    func dismiss() {
        detach(nameBubble)
        detach(hubTitle)
        orderOut(nil)
        clear()
    }

    /// Removes the tiles (and the tooltip or notice that may belong to one of them).
    private func clear() {
        hideTooltip()
        endNotice()
        items.forEach { $0.removeFromSuperview() }
        items = []
        decorations.forEach { $0.removeFromSuperview() }
        decorations = []
        tilesShown = []
    }
}

/// The window switcher's tint, in the hue of the system Accent color (System Settings → Appearance), at the
/// strength each part of the panel needs to read clearly in Light and Dark.
struct AccentTint {
    enum Role { case glass, wash, border }

    private let hue: CGFloat
    /// How colorful the accent color is, 0…1; near 0 for Graphite, so the tint turns gray instead of a random hue.
    private let colorfulness: CGFloat
    private let dark: Bool

    @MainActor
    init(appearance: NSAppearance) {
        var color = NSColor.gray
        // A dynamic color: resolved in the panel's appearance, and following the setting as it changes.
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .gray
        }
        // Only its hue is used; each role sets its own saturation and brightness.
        hue = color.hueComponent
        colorfulness = min(1, color.saturationComponent / 0.25)
        dark = appearance.isDark
    }

    func color(_ role: Role) -> NSColor {
        let (s, b, a): (CGFloat, CGFloat, CGFloat)
        switch (role, dark) {
        case (.glass, false): (s, b, a) = (0.75, 1.0, 0.30)
        case (.glass, true): (s, b, a) = (0.80, 1.0, 0.30)
        case (.wash, false): (s, b, a) = (0.65, 1.0, 0.38)
        case (.wash, true): (s, b, a) = (0.84, 0.95, 0.42)
        case (.border, false): (s, b, a) = (0.82, 0.85, 0.45)
        case (.border, true): (s, b, a) = (0.55, 1.0, 0.6)
        }
        return NSColor(colorSpace: .sRGB, hue: hue, saturation: s * colorfulness, brightness: b, alpha: a)
    }
}
