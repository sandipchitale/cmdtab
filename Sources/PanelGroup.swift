import AppKit

/// The switcher grid on one or more displays: one panel per display it's shown on, all showing the same tiles and
/// selection. The first panel is on the display with the pointer (or the active window) and drives grid navigation.
@MainActor
final class PanelGroup {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onRightClick: ((Int, NSEvent) -> Void)?
    var onPreviewHover: ((Int) -> Void)?
    var onPreviewClick: ((Int) -> Void)?
    var onPreviewRightClick: ((Int, NSEvent) -> Void)?
    /// A hover button (close, minimize, fill) on a tile, or on a preview.
    var onWindowButton: ((Int, WindowButton) -> Void)?
    var onPreviewWindowButton: ((Int, WindowButton) -> Void)?
    /// The search's clear button was clicked.
    var onSearchClear: (() -> Void)?

    private var panels: [SwitcherPanel] = []
    private var shownPanels: ArraySlice<SwitcherPanel> = []
    /// The displays for this session, picked when the grid first appears so redraws don't make it jump.
    private var screens: [NSScreen] = []
    /// Window-preview strips, one under each shown panel (the Dock's selected app).
    private var previewPanels: [SwitcherPanel] = []
    /// In a ring, the window previews instead: one card per window, in an arc just outside the ring around the selected
    /// tile; `arcCount` cards for each shown panel, in order.
    private var arcCards: [SwitcherPanel] = []
    private var arcCount = 0
    private static let arcTileWidth: CGFloat = 170
    /// The ? help, over the first panel, while it's shown.
    private let helpBubble = HelpBubble()
    /// The search (F), over the first panel, while it's on.
    private lazy var searchBubble: SearchBubble = {
        let bubble = SearchBubble()
        bubble.onClear = { [weak self] in self?.onSearchClear?() }
        return bubble
    }()
    /// The window switcher (not the Dock) is tinted with the Accent color, its preview strips too.
    private var tinted = false
    private var help: (title: String, sections: [KeyHelp.Section])?
    private var search: SearchText?

    /// What the search bubble shows: what's typed (or, while that's empty, `placeholder`), then any keys it refused (in
    /// red), and a hint after it; with a caret while keys type into it, dimmed while it's read-only. `symbol` is its
    /// icon: the bubble is also a label (Z's apps, a switcher kept open, a tip), with an empty query.
    typealias SearchText = (query: String, placeholder: String, hint: String, typing: Bool, symbol: String, refused: String)

    var isVisible: Bool { shownPanels.first?.isVisible ?? false }
    var columns: Int { shownPanels.first?.columns ?? 1 }

    /// Wires `panel` to this group's callbacks: a grid's, or (`preview`) the window previews', whose first tile is
    /// preview `offset` (a card in a ring's arc shows a single one).
    private func wire(_ panel: SwitcherPanel, preview: Bool, offset: Int = 0) {
        if preview {
            panel.onHover = { [weak self] i in self?.onPreviewHover?(offset + i) }
            panel.onClick = { [weak self] i in self?.onPreviewClick?(offset + i) }
            panel.onRightClick = { [weak self] i, event in self?.onPreviewRightClick?(offset + i, event) }
            panel.onWindowButton = { [weak self] i, button in self?.onPreviewWindowButton?(offset + i, button) }
        } else {
            panel.onHover = { [weak self] i in self?.onHover?(i) }
            panel.onClick = { [weak self] i in self?.onClick?(i) }
            panel.onRightClick = { [weak self] i, event in self?.onRightClick?(i, event) }
            panel.onWindowButton = { [weak self] i, button in self?.onWindowButton?(i, button) }
        }
    }

    /// Grows `pool` to `count` panels, and puts away any beyond that.
    private func fill(_ pool: inout [SwitcherPanel], to count: Int, preview: Bool) {
        while pool.count < count {
            let panel = SwitcherPanel()
            wire(panel, preview: preview)
            pool.append(panel)
        }
        pool[count...].forEach { $0.dismiss() }
    }

    /// Shows the grid on every display, or on the one with the pointer or the active window, per the settings; around a
    /// ring with Settings.ring (R). A Dock-style row shrinks down to `smallestRowSide` before it wraps.
    func show(tiles: [SwitcherTile], selected: Int, thumbnails: Bool,
              dockStyle: Bool = false, dividers: Set<Int> = [], iconsLikeDock: (count: Int, gaps: Int)? = nil,
              sizingCount: Int? = nil, smallestRowSide: CGFloat = 36) {
        if screens.isEmpty {
            let pointer = NSScreen.containing(NSEvent.mouseLocation)
            if Settings.showOnAllDisplays {
                screens = [pointer] + NSScreen.screens.filter { $0 != pointer }
            } else {
                screens = [Settings.switcherDisplay == "activeWindow" ? Self.activeWindowScreen() ?? pointer : pointer]
            }
        }
        tinted = !dockStyle
        fill(&panels, to: screens.count, preview: false)
        shownPanels = panels[..<screens.count]
        for (panel, screen) in zip(shownPanels, screens) {
            panel.show(tiles: tiles, selected: selected, on: screen, thumbnails: thumbnails,
                       dockStyle: dockStyle, dividers: dividers, iconsLikeDock: iconsLikeDock, ring: Settings.ring,
                       tinted: tinted, sizingCount: sizingCount, smallestRowSide: smallestRowSide)
        }
        placeSearch()
        placeHelp()
        if numbersVisible { shownPanels.forEach { $0.setNumbersVisible(true) } }
    }

    /// Whether the Dock's Fn+number badges are shown (while Fn is held); kept across redraws.
    private var numbersVisible = false

    func setNumbersVisible(_ visible: Bool) {
        numbersVisible = visible
        shownPanels.forEach { $0.setNumbersVisible(visible) }
    }

    /// Says why a key did nothing, in place of a beep: `text` for a moment where the selected item's name goes, on
    /// every panel. VoiceOver reads it out.
    func showNotice(_ text: String) {
        guard isVisible else { return }
        shownPanels.forEach { $0.showNotice(text) }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Shows the search over the first panel, or with nil hides it.
    func setSearch(_ search: SearchText?) {
        self.search = search
        placeSearch()
        placeHelp()
    }

    private func placeSearch() {
        guard let search, let panel = shownPanels.first, panel.isVisible else { return hideSearch() }
        let point: NSPoint
        var maxWidth = SearchBubble.maxWidth
        if let ring = panel.ring {
            // In the ring's see-through middle, above the selected tile's name: outside it, the window previews' arc
            // can be anywhere around the ring.
            point = NSPoint(x: panel.frame.minX + ring.center.x,
                            y: panel.frame.minY + ring.center.y + max(44, ring.hubRadius * 0.3))
            maxWidth = min(maxWidth, ring.hubRadius * 1.6)
        } else {
            // Above the panel, clear of the selected item's name bubble.
            point = NSPoint(x: panel.frame.midX, y: panel.frame.maxY + 36)
        }
        searchBubble.show(search, centeredAbove: point, maxWidth: maxWidth, appearance: panel.contentAppearance)
        panel.attach(searchBubble)
    }

    private func hideSearch() {
        shownPanels.first?.detach(searchBubble)
        searchBubble.orderOut(nil)
    }

    /// Shows the help (`title` over sections of keys and what they do) over the first panel, or hides it if it's shown.
    func toggleHelp(title: String, sections: [KeyHelp.Section]) {
        if help == nil {
            help = (title, sections)
            placeHelp()
        } else {
            hideHelp()
        }
    }

    private func placeHelp() {
        guard let help, let panel = shownPanels.first, panel.isVisible else { return }
        // A ring fills most of the screen: the help goes in its middle. Otherwise it goes above the search, if that's on.
        let ring = panel.ring != nil
        let over = search != nil && !ring ? panel.frame.union(searchBubble.frame) : panel.frame
        helpBubble.show(title: help.title, sections: help.sections, over: over, centered: ring, appearance: panel.contentAppearance)
        panel.attach(helpBubble)
    }

    private func hideHelp() {
        help = nil
        shownPanels.first?.detach(helpBubble)
        helpBubble.orderOut(nil)
    }

    /// Where tile `index` of the first panel is on screen, or (`preview`) preview `index` under it.
    func tileScreenFrame(_ index: Int, preview: Bool = false) -> NSRect? {
        if preview && arcCount > 0 { return arcCards.indices.contains(index) ? arcCards[index].tileScreenFrame(0) : nil }
        return (preview ? previewPanels.first : shownPanels.first)?.tileScreenFrame(index)
    }

    func setSelected(_ index: Int) {
        if isVisible { shownPanels.forEach { $0.setSelected(index) } }
    }

    func setThumbnail(_ image: CGImage, for id: CGWindowID) {
        shownPanels.forEach { $0.setThumbnail(image, for: id) }
    }

    /// Shows `tiles` as window previews hanging under tile `index` of each shown panel, or in an arc around it in a ring;
    /// `selected` nil highlights none.
    func showPreviews(tiles: [SwitcherTile], under index: Int, selected: Int?) {
        if shownPanels.first?.ring != nil { return showArc(tiles: tiles, around: index, selected: selected) }
        hideArc()
        fill(&previewPanels, to: shownPanels.count, preview: true)
        for (panel, preview) in zip(shownPanels, previewPanels) {
            guard let tile = panel.tileScreenFrame(index), let screen = panel.screen else { continue }
            preview.show(tiles: tiles, selected: selected ?? -1, on: screen, thumbnails: true,
                         placement: .below(topCenter: NSPoint(x: tile.midX, y: panel.frame.minY - 8)), maxTileWidth: 240, tinted: tinted)
        }
    }

    /// In a ring: a card per window, in an arc just outside the ring, centered on tile `index` and going clockwise.
    private func showArc(tiles: [SwitcherTile], around index: Int, selected: Int?) {
        previewPanels.forEach { $0.dismiss() }
        arcCount = tiles.count
        fill(&arcCards, to: tiles.count * shownPanels.count, preview: true)
        for (p, panel) in shownPanels.enumerated() {
            guard let anchor = panel.ringAnchor(for: index), let screen = panel.screen else { continue }
            let card = TileLayout(count: 1, area: screen.visibleFrame, thumbnails: true, dockStyle: false, dividers: [],
                                  iconsLikeDock: nil, maxTileWidth: Self.arcTileWidth).size
            let centers = Self.arcCenters(count: tiles.count, card: card, ring: anchor)
            for (k, tile) in tiles.enumerated() {
                let cardPanel = arcCards[p * tiles.count + k]
                wire(cardPanel, preview: true, offset: k)
                cardPanel.show(tiles: [tile], selected: k == selected ? 0 : -1, on: screen, thumbnails: true,
                               placement: .at(center: centers[k]), maxTileWidth: Self.arcTileWidth, tinted: tinted)
            }
        }
    }

    /// Centers (screen coordinates) for `count` cards of size `card` in an arc just outside a ring (its center and outer
    /// radius), centered on `angle` and going clockwise: an odd count has one straight out from the tile.
    private static func arcCenters(count: Int, card: CGSize, ring: (center: NSPoint, radius: CGFloat, angle: CGFloat)) -> [NSPoint] {
        let gap: CGFloat = 12
        // Neighbors a card's length apart along the arc's innermost circle, so they never overlap.
        let inner = ring.radius + gap + min(card.width, card.height) / 2
        var step = (max(card.width, card.height) + 10) / inner
        if CGFloat(count) * step > 2 * .pi { step = 2 * .pi / CGFloat(count) }
        return (0..<count).map { k in
            let angle = ring.angle + (CGFloat(count - 1) / 2 - CGFloat(k)) * step
            // Far enough out that the card's near edge is `gap` outside the ring.
            let radius = ring.radius + gap + card.extent(toward: angle)
            return NSPoint(x: ring.center.x + radius * cos(angle), y: ring.center.y + radius * sin(angle))
        }
    }

    private func hideArc() {
        arcCards.forEach { $0.dismiss() }
        arcCount = 0
    }

    func setPreviewSelected(_ index: Int?) {
        previewPanels.forEach { $0.setSelected(index ?? -1) }
        guard arcCount > 0 else { return }
        for (j, card) in arcCards.enumerated() { card.setSelected(j % arcCount == index ? 0 : -1) }
    }

    func setPreviewThumbnail(_ image: CGImage, for id: CGWindowID) {
        previewPanels.forEach { $0.setThumbnail(image, for: id) }
        arcCards.forEach { $0.setThumbnail(image, for: id) }
    }

    func hidePreviews() {
        previewPanels.forEach { $0.dismiss() }
        hideArc()
    }

    func dismiss() {
        hideHelp()
        search = nil
        hideSearch()
        hidePreviews()
        panels.forEach { $0.dismiss() }
        numbersVisible = false
        shownPanels = []
        screens = []
    }

    /// The display showing most of the frontmost window (the one you're switching away from).
    private static func activeWindowScreen() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let win = AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              let frame = AX.frame(win) else { return nil }
        return WindowGeometry.screen(around: frame)
    }
}
