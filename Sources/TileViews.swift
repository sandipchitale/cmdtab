import AppKit

/// One tile: an app icon (with state badge and running dot), or a window thumbnail under a header row.
@MainActor
final class SwitcherItemView: NSView {
    nonisolated static let headerHeight: CGFloat = 28

    var onHover: ((Int) -> Void)?
    var onHoverEnd: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onRightClick: ((Int, NSEvent) -> Void)?
    var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
    /// The selection's rounded square; in the ring, the ring draws the selection instead.
    var drawsHighlight = true
    let windowID: CGWindowID?

    private let index: Int
    private let showsThumbnail: Bool
    private let appIcon: NSImage
    private let iconView = NSImageView()
    private let imageView = NSImageView()
    private let frameView = ThumbnailFrame()
    private let inset: CGFloat = 8
    private static let badgeSize: CGFloat = 14

    init(frame: NSRect, tile: SwitcherTile, index: Int, thumbnail: Bool) {
        self.index = index
        self.windowID = tile.windowID
        self.showsThumbnail = thumbnail
        self.appIcon = tile.icon
        super.init(frame: frame)
        iconView.image = appIcon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        if thumbnail { layOutThumbnail(tile) } else { layOutIcon(tile) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Icon only; the panel shows the selected tile's name in a bubble above it.
    private func layOutIcon(_ tile: SwitcherTile) {
        let inset = (frame.width * 0.08).rounded()
        iconView.frame = bounds.insetBy(dx: inset, dy: inset)
        let badge = Self.badgeSize
        addBadge(for: tile, at: NSPoint(x: iconView.frame.maxX - badge - 2, y: iconView.frame.minY + 2))
        if tile.isRunning {
            // Like the Dock: a small dot just under the icon.
            let side: CGFloat = 5
            addSubview(RunningDot(frame: NSRect(x: bounds.midX - side / 2, y: max(1, iconView.frame.minY / 2 - side / 2),
                                                width: side, height: side)))
        }
    }

    /// Header row (small app icon + window title) with the snapshot underneath.
    private func layOutThumbnail(_ tile: SwitcherTile) {
        let iconSize: CGFloat = 18, badge = Self.badgeSize
        let headerMidY = frame.height - inset / 2 - Self.headerHeight / 2
        iconView.frame = NSRect(x: inset + 2, y: headerMidY - iconSize / 2, width: iconSize, height: iconSize)

        let label = NSTextField(labelWithString: tile.title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        let labelX = iconView.frame.maxX + 6
        var labelRight = frame.width - inset
        if addBadge(for: tile, at: NSPoint(x: frame.width - inset - 2 - badge, y: headerMidY - badge / 2)) {
            labelRight -= badge + 6
        }
        label.frame = NSRect(x: labelX, y: headerMidY - 9, width: labelRight - labelX, height: 18)
        addSubview(label)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
        // The same frame on every tile, whatever the window's shape, over the snapshot.
        frameView.frame = thumbnailArea
        addSubview(frameView)
        if let id = tile.windowID, let image = Thumbnails.shared.cached(id) { setThumbnail(image) } else { showPlaceholder() }
    }

    /// Adds the minimized / hidden-app badge at `origin`, if the tile needs one. Returns whether it did.
    @discardableResult
    private func addBadge(for tile: SwitcherTile, at origin: NSPoint) -> Bool {
        guard tile.isMinimized || tile.isAppHidden else { return false }
        addSubview(StateBadge(frame: NSRect(origin: origin, size: NSSize(width: Self.badgeSize, height: Self.badgeSize)),
                              minimized: tile.isMinimized, hidden: tile.isAppHidden))
        return true
    }

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
        guard isSelected, drawsHighlight else { return }
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
        (effectiveAppearance.isDark ? NSColor.white.withAlphaComponent(0.25) : NSColor.black.withAlphaComponent(0.35)).setFill()
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

/// The ring layout's band, drawn behind its tiles: a hairline around the hub, and the selected tile's wedge, inset and
/// rounded like WindowRing's.
final class RingBandView: NSView {
    var geometry: RingGeometry? { didSet { needsDisplay = true } }
    var selected = -1 { didSet { if oldValue != selected { needsDisplay = true } } }
    /// Like a pie menu: the pointer anywhere on the band points at the tile in that direction.
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onRightClick: ((Int, NSEvent) -> Void)?

    /// The band takes the mouse (under the tiles, which handle their own clicks); the hub and the corners don't.
    override func hitTest(_ point: NSPoint) -> NSView? {
        geometry?.index(at: convert(point, from: superview)) == nil ? nil : self
    }

    private func index(of event: NSEvent) -> Int? { geometry?.index(at: convert(event.locationInWindow, from: nil)) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { if let i = index(of: event) { onHover?(i) } }
    override func mouseMoved(with event: NSEvent) { if let i = index(of: event) { onHover?(i) } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { if let i = index(of: event) { onClick?(i) } }
    override func rightMouseDown(with event: NSEvent) { if let i = index(of: event) { onRightClick?(i, event) } }

    override func draw(_ dirtyRect: NSRect) {
        guard let ring = geometry else { return }
        let dark = effectiveAppearance.isDark
        let hub = ring.hubRadius
        // The hole's edge, just inside the band (the hole is cut out of the panel).
        let edge = hub + 0.5
        let hubCircle = NSBezierPath(ovalIn: NSRect(x: ring.center.x - edge, y: ring.center.y - edge, width: edge * 2, height: edge * 2))
        (dark ? NSColor.white.withAlphaComponent(0.35) : NSColor.black.withAlphaComponent(0.3)).setStroke()
        hubCircle.lineWidth = 1
        hubCircle.stroke()

        guard (0..<ring.count).contains(selected) else { return }
        // The same tone as the grid's selection square. At most a quarter turn wide, so a ring of a few tiles (or one)
        // doesn't light up a third of itself or more.
        (dark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.25)).setFill()
        let angle = ring.angle(selected), span = min(ring.step, .pi / 2)
        Self.wedge(center: ring.center, inner: hub, outer: ring.outerRadius, from: angle - span / 2, to: angle + span / 2).fill()
    }

    /// A slice of the band from `inner` to `outer` radius between two angles (radians, `start` < `end`), pulled in by
    /// `inset` on all four sides (by arc length, so the margin is even) and with rounded corners.
    static func wedge(center: NSPoint, inner: CGFloat, outer: CGFloat, from start: CGFloat, to end: CGFloat,
                      inset: CGFloat = 6, cornerRadius: CGFloat = 16) -> NSBezierPath {
        let path = NSBezierPath()
        let rIn = inner + inset, rOut = outer - inset
        guard rOut > rIn, rIn > 0 else { return path }
        let startIn = start + inset / rIn, endIn = end - inset / rIn
        let startOut = start + inset / rOut, endOut = end - inset / rOut
        guard endIn > startIn, endOut > startOut else { return path }

        func point(_ angle: CGFloat, _ r: CGFloat) -> NSPoint {
            NSPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
        func lerp(_ a: NSPoint, _ b: NSPoint, _ t: CGFloat) -> NSPoint {
            NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        func arc(from a0: CGFloat, to a1: CGFloat, r: CGFloat) {
            let steps = max(2, Int(abs(a1 - a0) / 0.03) + 1)
            for i in 1...steps { path.line(to: point(a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps), r)) }
        }

        // The four sharp corners the rounding replaces; each rounded corner is a curve with that corner as control.
        let c1 = point(startIn, rIn), c2 = point(startOut, rOut), c3 = point(endOut, rOut), c4 = point(endIn, rIn)
        let edge = hypot(c2.x - c1.x, c2.y - c1.y)
        let radius = max(0, min(cornerRadius, edge / 2, rIn * (endIn - startIn) / 2))
        let t = edge > 0 ? radius / edge : 0
        let inStep = radius / rIn, outStep = radius / rOut
        path.move(to: lerp(c1, c2, t))
        path.line(to: lerp(c2, c1, t))
        path.curve(to: point(startOut + outStep, rOut), controlPoint: c2)
        arc(from: startOut + outStep, to: endOut - outStep, r: rOut)
        path.curve(to: lerp(c3, c4, t), controlPoint: c3)
        path.line(to: lerp(c4, c3, t))
        path.curve(to: point(endIn - inStep, rIn), controlPoint: c4)
        arc(from: endIn - inStep, to: startIn + inStep, r: rIn)
        path.curve(to: lerp(c1, c2, t), controlPoint: c1)
        path.close()
        return path
    }
}

/// A hairline rounded border around a tile's thumbnail area, in the opposite tone of the appearance.
final class ThumbnailFrame: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let color = effectiveAppearance.isDark ? NSColor.white.withAlphaComponent(0.4) : NSColor.black.withAlphaComponent(0.4)
        color.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.lineWidth = 1
        path.stroke()
    }
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

/// Yellow badge for a window's state: a ring means its app is hidden, a centered dot (like the yellow minimize button in
/// a window's title bar) means the window is minimized. Both together show the ring around the same dot.
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
