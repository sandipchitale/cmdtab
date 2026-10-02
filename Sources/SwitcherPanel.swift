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

/// The floating Alt+Tab-style grid.
@MainActor
final class SwitcherPanel: OverlayPanel {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    private(set) var columns = 1

    /// Holds the tiles and the title label; sits inside the glass (or the fallback blur).
    private let content = NSView()
    /// Only in the pre-Liquid Glass fallback: tones down the blur's see-through look.
    private var tint: NSView?
    private let titleLabel = NSTextField(labelWithString: "")
    private let tooltip = TooltipWindow()
    private var pendingTooltip: DispatchWorkItem?
    private var tooltipIndex: Int?
    private var items: [SwitcherItemView] = []
    private var windowsShown: [SwitcherWindow] = []
    private var mouseAtShow = NSPoint.zero
    private var showsThumbnails = false

    private let padding: CGFloat = 20
    private let cornerRadius: CGFloat = 26
    /// Room under each row of icons for the selected window's title, like the native switcher.
    private let labelHeight: CGFloat = 22

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

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        content.addSubview(titleLabel)
    }

    func show(windows: [SwitcherWindow], selected: Int) {
        hideTooltip()
        windowsShown = windows
        items.forEach { $0.removeFromSuperview() }
        items = []

        let mouse = NSEvent.mouseLocation
        mouseAtShow = mouse
        let area = NSScreen.containing(mouse).visibleFrame

        switch Settings.appearance {
        case "light": contentAppearance = NSAppearance(named: .aqua)!
        case "dark": contentAppearance = NSAppearance(named: .darkAqua)!
        default: contentAppearance = NSApp.effectiveAppearance // follow the system
        }
        if let tint {
            contentAppearance.performAsCurrentDrawingAppearance {
                tint.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55).cgColor
            }
        }

        // Thumbnail tiles carry their own title; icon tiles show the selected window's title underneath.
        let thumbnails = Settings.showThumbnails
        showsThumbnails = thumbnails
        let spacing: CGFloat = 12
        let label = thumbnails ? 0 : labelHeight
        let sizes: [CGSize] = thumbnails
            ? ([320, 280, 240, 200, 170, 140] as [CGFloat]).map { CGSize(width: $0, height: ($0 * 0.62 + SwitcherItemView.headerHeight).rounded()) }
            : ([120, 104, 88, 76, 64] as [CGFloat]).map { CGSize(width: $0, height: $0) }

        // Pick the largest tile size that fits everything on screen.
        var tile = sizes[0]
        var height: CGFloat = 0
        for size in sizes {
            tile = size
            let maxCols = max(1, Int((area.width * 0.92 - padding * 2 + spacing) / (size.width + spacing)))
            columns = min(windows.count, maxCols)
            let rows = Int(ceil(Double(windows.count) / Double(columns)))
            height = CGFloat(rows) * (size.height + label + spacing) - spacing + padding * 2
            if height <= area.height * 0.9 { break }
        }

        let width = CGFloat(columns) * (tile.width + spacing) - spacing + padding * 2
        let frame = NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        setFrame(frame, display: false)
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        invalidateShadow()

        titleLabel.isHidden = thumbnails

        for (i, w) in windows.enumerated() {
            let col = i % columns
            let row = i / columns
            let x = padding + CGFloat(col) * (tile.width + spacing)
            let y = height - padding - tile.height - CGFloat(row) * (tile.height + label + spacing)
            let item = SwitcherItemView(frame: NSRect(x: x, y: y, width: tile.width, height: tile.height),
                                        window: w, index: i, thumbnail: thumbnails)
            // Hover drives two independent things: selection, and (icon view only) the title tooltip.
            item.onHover = { [weak self] idx in
                guard let self, NSEvent.mouseLocation != self.mouseAtShow else { return } // ignore until the mouse actually moves
                if !self.items[idx].isSelected { self.onHover?(idx) }
                if !thumbnails { self.scheduleTooltip(for: idx) }
            }
            item.onHoverEnd = { [weak self] idx in
                if self?.tooltipIndex == idx { self?.hideTooltip() }
            }
            item.onClick = { [weak self] idx in self?.onClick?(idx) }
            content.addSubview(item)
            items.append(item)
        }

        setSelected(selected)
        alphaValue = 1
        orderFrontRegardless()
    }

    func setSelected(_ index: Int) {
        for (i, item) in items.enumerated() { item.isSelected = i == index }
        guard !showsThumbnails, items.indices.contains(index) else { return }

        // Like the native switcher: the app name sits just below the selected icon, and may be wider than the tile.
        // The window title is in the hover tooltip.
        let w = windowsShown[index]
        titleLabel.stringValue = w.app.localizedName ?? w.title
        let tile = items[index].frame
        let bounds = content.bounds
        // Always centered on the icon; near the panel's edges a long name is truncated rather than shifted.
        let room = 2 * min(tile.midX - 8, bounds.width - 8 - tile.midX)
        let width = min(titleLabel.intrinsicContentSize.width + 8, room)
        titleLabel.frame = NSRect(x: tile.midX - width / 2, y: tile.minY - labelHeight + 3, width: width, height: 17)
    }

    /// Shows the hovered window's title after a short pause, like a tooltip.
    private func scheduleTooltip(for index: Int) {
        guard tooltipIndex != index, windowsShown.indices.contains(index) else { return }
        hideTooltip()
        tooltipIndex = index
        let title = windowsShown[index].title
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

    func dismiss() {
        hideTooltip()
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
    var onHoverEnd: ((Int) -> Void)?
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
            // Icon only; the selected window's title is shown below it by the panel.
            let inset = (frame.width * 0.08).rounded()
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
        contentAppearance = appearance
        label.stringValue = text
        let textSize = label.intrinsicContentSize
        let size = NSSize(width: min(textSize.width + 14, 600), height: textSize.height + 6)
        let screen = NSScreen.containing(point).visibleFrame
        var origin = NSPoint(x: point.x + 4, y: point.y - 22 - size.height)
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        origin.y = max(origin.y, screen.minY + 4)
        setFrame(NSRect(origin: origin, size: size), display: false)
        label.frame = NSRect(x: 7, y: 3, width: size.width - 14, height: textSize.height)
        orderFrontRegardless()
    }
}
