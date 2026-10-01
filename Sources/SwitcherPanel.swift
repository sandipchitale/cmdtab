import AppKit

/// The floating Alt+Tab-style grid. Never becomes key, so it never steals focus from the app you're leaving.
@MainActor
final class SwitcherPanel: NSPanel {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    private(set) var columns = 1

    private let background = NSVisualEffectView()
    private let tint = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var items: [SwitcherItemView] = []
    private var windowsShown: [SwitcherWindow] = []
    private var mouseAtShow = NSPoint.zero

    private let padding: CGFloat = 18
    private let titleHeight: CGFloat = 30
    private let cornerRadius: CGFloat = 18

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        // A layer corner radius doesn't clip behind-window blur (square corners leak out); a mask image does,
        // and the window shadow follows it.
        background.maskImage = Self.roundedMask(radius: cornerRadius)
        contentView = background

        // Tones down the material's see-through look. Its color is resolved per appearance in show().
        tint.wantsLayer = true
        tint.layer?.cornerRadius = cornerRadius
        tint.autoresizingMask = [.width, .height]
        background.addSubview(tint)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        background.addSubview(titleLabel)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(windows: [SwitcherWindow], selected: Int) {
        windowsShown = windows
        items.forEach { $0.removeFromSuperview() }
        items = []

        let mouse = NSEvent.mouseLocation
        mouseAtShow = mouse
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame

        switch Settings.appearance {
        case "light": appearance = NSAppearance(named: .aqua)
        case "dark": appearance = NSAppearance(named: .darkAqua)
        default: appearance = nil // follow the system
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55).cgColor
        }

        // Thumbnail tiles carry their own title; icon tiles share one header above the grid.
        let thumbnails = Settings.showThumbnails
        let spacing: CGFloat = thumbnails ? 12 : 6
        let header = thumbnails ? 0 : titleHeight
        let sizes: [CGSize] = thumbnails
            ? ([320, 280, 240, 200, 170, 140] as [CGFloat]).map { CGSize(width: $0, height: ($0 * 0.62 + SwitcherItemView.headerHeight).rounded()) }
            : ([112, 96, 84, 72, 60] as [CGFloat]).map { CGSize(width: $0, height: $0) }

        // Pick the largest tile size that fits everything on screen.
        var tile = sizes[0]
        var rows = 1
        for size in sizes {
            tile = size
            let maxCols = max(1, Int((area.width * 0.92 - padding * 2 + spacing) / (size.width + spacing)))
            columns = min(windows.count, maxCols)
            rows = Int(ceil(Double(windows.count) / Double(columns)))
            let h = CGFloat(rows) * (size.height + spacing) - spacing + padding * 2 + header
            if h <= area.height * 0.9 { break }
        }

        let width = CGFloat(columns) * (tile.width + spacing) - spacing + padding * 2
        let height = CGFloat(rows) * (tile.height + spacing) - spacing + padding * 2 + header
        let frame = NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        setFrame(frame, display: false)
        tint.frame = background.bounds
        invalidateShadow()

        titleLabel.isHidden = thumbnails
        titleLabel.frame = NSRect(x: padding, y: height - padding - titleHeight + 6, width: width - padding * 2, height: 22)

        for (i, w) in windows.enumerated() {
            let col = i % columns
            let row = i / columns
            let x = padding + CGFloat(col) * (tile.width + spacing)
            let y = height - padding - header - CGFloat(row + 1) * tile.height - CGFloat(row) * spacing
            let item = SwitcherItemView(frame: NSRect(x: x, y: y, width: tile.width, height: tile.height),
                                        window: w, index: i, thumbnail: thumbnails)
            item.onHover = { [weak self] idx in
                guard let self, NSEvent.mouseLocation != self.mouseAtShow else { return } // ignore until the mouse actually moves
                self.onHover?(idx)
            }
            item.onClick = { [weak self] idx in self?.onClick?(idx) }
            background.addSubview(item)
            items.append(item)
        }

        setSelected(selected)
        alphaValue = 1
        orderFrontRegardless()
    }

    func setSelected(_ index: Int) {
        for (i, item) in items.enumerated() { item.isSelected = i == index }
        if windowsShown.indices.contains(index) {
            // The app is evident from the selected icon, so the header shows just the window title.
            let w = windowsShown[index]
            titleLabel.stringValue = w.title
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
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

    func setThumbnail(_ image: CGImage, for id: CGWindowID) {
        for item in items where item.windowID == id { item.setThumbnail(image) }
    }

    func dismiss() {
        orderOut(nil)
        items.forEach { $0.removeFromSuperview() }
        items = []
        windowsShown = []
    }
}

@MainActor
final class SwitcherItemView: NSView {
    static let headerHeight: CGFloat = 28

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
    let windowID: CGWindowID

    private let index: Int
    private let showsThumbnail: Bool
    private let appIcon: NSImage
    private let iconView = NSImageView()
    private let imageView = NSImageView()
    private let inset: CGFloat = 8

    init(frame: NSRect, window: SwitcherWindow, index: Int, thumbnail: Bool) {
        self.index = index
        self.windowID = window.id
        self.showsThumbnail = thumbnail
        self.appIcon = window.app.icon ?? NSImage()
        super.init(frame: frame)

        let badgeSize: CGFloat = 14
        guard thumbnail else {
            // Icon only; the selected window's title is shown in the panel header.
            let inset = (frame.width * 0.12).rounded()
            iconView.image = appIcon
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.frame = bounds.insetBy(dx: inset, dy: inset)
            addSubview(iconView)
            if window.isMinimized || window.isAppHidden {
                addSubview(StateBadge(frame: NSRect(x: iconView.frame.maxX - badgeSize - 2, y: iconView.frame.minY + 2,
                                                    width: badgeSize, height: badgeSize),
                                      minimized: window.isMinimized, hidden: window.isAppHidden))
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

        let label = NSTextField(labelWithString: window.title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        let labelX = iconView.frame.maxX + 6
        var labelRight = frame.width - inset
        if window.isMinimized || window.isAppHidden {
            labelRight -= badgeSize + 6
            addSubview(StateBadge(frame: NSRect(x: frame.width - inset - 2 - badgeSize, y: headerMidY - badgeSize / 2,
                                                width: badgeSize, height: badgeSize),
                                  minimized: window.isMinimized, hidden: window.isAppHidden))
        }
        label.frame = NSRect(x: labelX, y: headerMidY - 9, width: labelRight - labelX, height: 18)
        addSubview(label)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
        if let image = Thumbnails.shared.cached(window.id) { setThumbnail(image) } else { showPlaceholder() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var thumbnailArea: NSRect {
        NSRect(x: inset, y: inset, width: bounds.width - inset * 2, height: bounds.height - inset - inset / 2 - Self.headerHeight)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
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
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 12, yRadius: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2.5
        path.stroke()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHover?(index) }
    override func mouseMoved(with event: NSEvent) { if !isSelected { onHover?(index) } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(index) }
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
