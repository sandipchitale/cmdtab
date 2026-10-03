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
    let windowID: CGWindowID?

    private let index: Int
    private let showsThumbnail: Bool
    private let appIcon: NSImage
    private let iconView = NSImageView()
    private let imageView = NSImageView()
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
