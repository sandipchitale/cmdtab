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

    /// Shows `child` attached above this panel, so it moves and closes with it.
    func attach(_ child: NSWindow) {
        if child.parent == nil { addChildWindow(child, ordered: .above) }
    }

    /// Hides an attached `child`.
    func detach(_ child: NSWindow) {
        if child.parent != nil { removeChildWindow(child) }
        child.orderOut(nil)
    }
}

extension NSScreen {
    /// The screen containing `point` (screen coordinates), falling back to the main screen.
    static func containing(_ point: NSPoint) -> NSScreen {
        screens.first { NSMouseInRect(point, $0.frame, false) } ?? main ?? screens[0]
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// The panels' appearance, per the Appearance setting.
    @MainActor
    static var forPanels: NSAppearance {
        switch Settings.appearance {
        case "light": NSAppearance(named: .aqua)!
        case "dark": NSAppearance(named: .darkAqua)!
        default: NSApp.effectiveAppearance // follow the system
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
