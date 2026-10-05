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

extension NSEvent {
    /// Where a mouse event happened, in screen coordinates.
    @MainActor
    var screenLocation: NSPoint { window?.convertPoint(toScreen: locationInWindow) ?? NSEvent.mouseLocation }
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

/// A bubble of text that floats over the switcher and lets clicks through: a label on a rounded, blurred background.
@MainActor
class BubblePanel: OverlayPanel {
    let label = NSTextField(labelWithString: "")
    /// The background, which subclasses add to.
    let background = NSVisualEffectView()

    init(material: NSVisualEffectView.Material, radius: CGFloat) {
        super.init()
        ignoresMouseEvents = true
        background.material = material
        background.state = .active
        background.maskImage = roundedMaskImage(radius: radius)
        contentView = background
        background.addSubview(label)
    }
}

/// A tooltip look-alike. Real tooltips don't appear in the switcher, because it's a panel that never becomes active.
@MainActor
final class TooltipWindow: BubblePanel {
    init() {
        super.init(material: .toolTip, radius: 5)
        label.font = .toolTipsFont(ofSize: 0)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
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

/// The ring's title, in its see-through middle: the selected tile's name (and title) on a small bordered card, so it
/// reads over whatever is behind the ring.
@MainActor
final class HubTitle: BubblePanel {
    private let edge = NSView()
    private static let padding = NSSize(width: 18, height: 10), radius: CGFloat = 12

    init() {
        super.init(material: .popover, radius: Self.radius)
        label.maximumNumberOfLines = 3
        edge.wantsLayer = true
        edge.layer?.cornerRadius = Self.radius
        edge.layer?.borderWidth = 1
        edge.autoresizingMask = [.width, .height]
        background.addSubview(edge)
    }

    /// Shows `name`, with `title` under it when that says more, on a card at most `maxWidth` wide centered on `center`
    /// (screen coordinates).
    func show(name: String, title: String, maxWidth: CGFloat, centeredOn center: NSPoint, appearance: NSAppearance) {
        contentAppearance = appearance
        edge.layer?.borderColor = (appearance.isDark ? NSColor.white.withAlphaComponent(0.3)
                                                     : NSColor.black.withAlphaComponent(0.2)).cgColor
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ])
        if title != name {
            text.append(NSAttributedString(string: "\n" + title, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
            ]))
        }
        label.attributedStringValue = text
        let pad = Self.padding
        let fit = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxWidth - pad.width * 2, height: 400)) ?? .zero
        let textSize = NSSize(width: ceil(fit.width), height: ceil(fit.height))
        label.frame = NSRect(x: pad.width, y: pad.height, width: textSize.width, height: textSize.height)
        let size = NSSize(width: textSize.width + pad.width * 2, height: textSize.height + pad.height * 2)
        setFrame(NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                 display: true)
        orderFrontRegardless()
    }
}

/// An image that runs `onClick` when clicked, even in a panel that never becomes key.
@MainActor
final class ClickableImage: NSImageView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The search (F) over the switcher or the Dock: a magnifying glass, what's typed (or a placeholder) at a caret, a
/// hint (how many match, what keys do), and a clear button, on a small bordered card like the ring's title. Read-only,
/// it's dimmed and has no caret.
@MainActor
final class SearchBubble: BubblePanel {
    private let icon = NSImageView()
    private let clear = ClickableImage()
    private let edge = NSView()
    /// The clear button was clicked.
    var onClear: (() -> Void)?
    private static let padding = NSSize(width: 12, height: 7), radius: CGFloat = 10
    private static let iconSide: CGFloat = 16, iconGap: CGFloat = 6, clearSide: CGFloat = 15
    /// The widest it gets; a longer search loses its start.
    static let maxWidth: CGFloat = 600

    init() {
        super.init(material: .popover, radius: Self.radius)
        icon.contentTintColor = .secondaryLabelColor
        background.addSubview(icon)
        edge.wantsLayer = true
        edge.layer?.cornerRadius = Self.radius
        edge.layer?.borderWidth = 1
        edge.autoresizingMask = [.width, .height]
        background.addSubview(edge)
        // Over the edge, which would otherwise take its clicks; the rest of the bubble ignores them.
        ignoresMouseEvents = false
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        clear.contentTintColor = .tertiaryLabelColor
        clear.toolTip = "Clear"
        clear.onClick = { [weak self] in self?.onClear?() }
        background.addSubview(clear)
    }

    /// Shows the search's text, at most `maxWidth` wide, centered horizontally on `point` (screen coordinates) with its
    /// bottom edge there, kept on screen.
    func show(_ search: PanelGroup.SearchText, centeredAbove point: NSPoint, maxWidth: CGFloat, appearance: NSAppearance) {
        let (query, placeholder, hint, typing, symbol, refused) = search
        contentAppearance = appearance
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        edge.layer?.borderColor = (appearance.isDark ? NSColor.white.withAlphaComponent(0.3)
                                                     : NSColor.black.withAlphaComponent(0.2)).cgColor
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let empty = query.isEmpty && refused.isEmpty
        /// What's typed (or the placeholder), the keys it refused, then `hint`, if any.
        func text(hint: String?) -> NSMutableAttributedString {
            let text = NSMutableAttributedString(string: query, attributes: [
                .font: font, .foregroundColor: typing ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
            text.append(NSAttributedString(string: refused, attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
            if typing {
                text.append(NSAttributedString(string: "|", attributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .light), .foregroundColor: NSColor.controlAccentColor,
                ]))
            }
            if empty {
                // As a label (Z's apps, kept open, a tip), it reads more clearly than a placeholder would.
                text.append(NSAttributedString(string: placeholder, attributes: [
                    .font: font, .foregroundColor: typing ? NSColor.placeholderTextColor : NSColor.secondaryLabelColor,
                ]))
            }
            if let hint, !hint.isEmpty {
                text.append(NSAttributedString(string: "    " + hint, attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            return text
        }
        icon.contentTintColor = typing || query.isEmpty ? .secondaryLabelColor : .tertiaryLabelColor

        let pad = Self.padding
        // The clear button, after the hint, only with something to clear.
        clear.isHidden = empty
        let clearWidth = empty ? 0 : Self.iconGap + Self.clearSide
        let maxTextWidth = maxWidth - pad.width * 2 - Self.iconSide - Self.iconGap - clearWidth
        // Where room is short (the middle of a ring), the hint gives way first: down to its first part (how many match),
        // then altogether. Only then does the search itself lose its start.
        let shortHint = hint.components(separatedBy: " · ").first
        let candidates = [text(hint: hint), text(hint: shortHint), text(hint: nil)]
        let attributed = candidates.first { ceil($0.size().width) + 4 <= maxTextWidth } ?? candidates[candidates.count - 1]
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingHead
        attributed.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: attributed.length))
        label.attributedStringValue = attributed
        let cell = label.cell?.cellSize ?? label.intrinsicContentSize
        let textSize = NSSize(width: min(ceil(cell.width), maxTextWidth), height: ceil(cell.height))
        let size = NSSize(width: pad.width * 2 + Self.iconSide + Self.iconGap + textSize.width + clearWidth,
                          height: max(textSize.height, Self.iconSide) + pad.height * 2)
        icon.frame = NSRect(x: pad.width, y: ((size.height - Self.iconSide) / 2).rounded(), width: Self.iconSide, height: Self.iconSide)
        label.frame = NSRect(x: pad.width + Self.iconSide + Self.iconGap, y: ((size.height - textSize.height) / 2).rounded(),
                             width: textSize.width, height: textSize.height)
        clear.frame = NSRect(x: label.frame.maxX + Self.iconGap, y: ((size.height - Self.clearSide) / 2).rounded(),
                             width: Self.clearSide, height: Self.clearSide)

        let screen = NSScreen.containing(point).visibleFrame
        let origin = NSPoint(x: min(max(point.x - size.width / 2, screen.minX + 4), screen.maxX - size.width - 4),
                             y: min(max(point.y, screen.minY + 4), screen.maxY - size.height - 4))
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
    }
}

/// Why a key did nothing (Finder can't be quit, an app has no New Window, ...), in place of a beep: a line of text on a
/// small bordered card like the search's, where the selected item's name goes. Its panel fades it away.
@MainActor
final class NoticeBubble: BubblePanel {
    private let icon = NSImageView()
    private let edge = NSView()
    private static let padding = NSSize(width: 10, height: 5), radius: CGFloat = 9
    private static let iconSide: CGFloat = 15, iconGap: CGFloat = 5, maxTextWidth: CGFloat = 560

    init() {
        super.init(material: .popover, radius: Self.radius)
        icon.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        icon.contentTintColor = .secondaryLabelColor
        background.addSubview(icon)
        edge.wantsLayer = true
        edge.layer?.cornerRadius = Self.radius
        edge.layer?.borderWidth = 1
        edge.autoresizingMask = [.width, .height]
        background.addSubview(edge)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
    }

    /// Shows `text` centered horizontally on `point` (screen coordinates) with its bottom edge there, kept on screen.
    func show(_ text: String, centeredAbove point: NSPoint, appearance: NSAppearance) {
        contentAppearance = appearance
        edge.layer?.borderColor = (appearance.isDark ? NSColor.white.withAlphaComponent(0.3)
                                                     : NSColor.black.withAlphaComponent(0.2)).cgColor
        label.stringValue = text
        let cell = label.cell?.cellSize ?? label.intrinsicContentSize
        let textSize = NSSize(width: min(ceil(cell.width), Self.maxTextWidth), height: ceil(cell.height))
        let pad = Self.padding
        let size = NSSize(width: pad.width * 2 + Self.iconSide + Self.iconGap + textSize.width,
                          height: max(textSize.height, Self.iconSide) + pad.height * 2)
        icon.frame = NSRect(x: pad.width, y: ((size.height - Self.iconSide) / 2).rounded(), width: Self.iconSide, height: Self.iconSide)
        label.frame = NSRect(x: pad.width + Self.iconSide + Self.iconGap, y: ((size.height - textSize.height) / 2).rounded(),
                             width: textSize.width, height: textSize.height)
        let screen = NSScreen.containing(point).visibleFrame
        let origin = NSPoint(x: min(max(point.x - size.width / 2, screen.minX + 4), screen.maxX - size.width - 4),
                             y: min(max(point.y, screen.minY + 4), screen.maxY - size.height - 4))
        alphaValue = 1
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
    }
}

/// A small panel listing a switcher's keys and mouse actions, toggled with ?.
@MainActor
final class HelpBubble: BubblePanel {
    private static let inset: CGFloat = 12

    init() {
        super.init(material: .popover, radius: 10)
        label.maximumNumberOfLines = 0
    }

    /// Shows `title` over two columns of (keys, what they do), in sections, centered above `panel` (screen
    /// coordinates), or below it if there's no room above; or (`centered`) in its middle.
    func show(title: String, sections: [KeyHelp.Section], over panel: NSRect, centered: Bool = false, appearance: NSAppearance) {
        contentAppearance = appearance
        label.attributedStringValue = Self.text(title: title, sections: sections)
        let textSize = label.cell?.cellSize ?? label.intrinsicContentSize
        let size = NSSize(width: ceil(textSize.width) + Self.inset * 2, height: ceil(textSize.height) + Self.inset * 2)
        label.frame = NSRect(x: Self.inset, y: Self.inset, width: ceil(textSize.width), height: ceil(textSize.height))

        let screen = NSScreen.containing(NSPoint(x: panel.midX, y: panel.midY)).visibleFrame
        // Above the panel, clear of the name bubble over it; below if that runs off the top of the screen.
        var origin = NSPoint(x: panel.midX - size.width / 2, y: panel.maxY + 36)
        if centered {
            origin.y = panel.midY - size.height / 2
        } else if origin.y + size.height > screen.maxY {
            origin.y = panel.minY - 8 - size.height
        }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        origin.y = max(origin.y, screen.minY + 4)
        setFrame(NSRect(origin: origin, size: size), display: false)
        orderFrontRegardless()
    }

    /// `title` over two columns of (keys, what they do), with a little space between sections, as the help shows it.
    static func text(title: String, sections: [KeyHelp.Section]) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12), keyFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let rows = sections.flatMap { $0 }
        // The actions line up in a second column, just past the widest keys.
        let keyWidth = rows.map { ($0.0 as NSString).size(withAttributes: [.font: keyFont]).width }.max() ?? 0
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: ceil(keyWidth) + 16)]
        style.lineSpacing = 2
        // The first row of each section after the first starts a little lower.
        let sectionStyle = style.mutableCopy() as! NSMutableParagraphStyle
        sectionStyle.paragraphSpacingBefore = 7

        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.labelColor,
        ])
        for (s, section) in sections.enumerated() {
            for (r, (keys, action)) in section.enumerated() {
                let paragraph = s > 0 && r == 0 ? sectionStyle : style
                text.append(NSAttributedString(string: "\n" + keys, attributes: [
                    .font: keyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
                ]))
                text.append(NSAttributedString(string: "\t" + action, attributes: [
                    .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
                ]))
            }
        }
        return text
    }
}
