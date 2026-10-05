import AppKit

/// State machine for one Cmd+Tab session: begin -> move* -> commit | cancel.
@MainActor
final class SwitcherController {
    private let panels = PanelGroup()
    /// Every window listed, most recently used first.
    private var windows: [SwitcherWindow] = []
    /// The selected tile: a window, or (grouped) an app.
    private var selected = 0
    private var pendingShow: DispatchWorkItem?
    private var running = false
    /// G: one tile per app instead of per window, with the selected app's windows previewed under it. Icon view only,
    /// and for this session only.
    private var grouped = false
    /// The single-window preview, or (grouped) the selected app's windows.
    private lazy var previews = WindowPreviews(panels: panels)
    private var thumbnailsRequested = false

    /// True while a tile's tiling menu is tracking; releasing Cmd doesn't switch then.
    private(set) var menuOpen = false

    /// Called when a switch finishes by some route other than releasing Cmd (mouse click, tiling menu).
    var onFinished: (() -> Void)?

    /// A quick Cmd+Tab tap shorter than this switches without ever flashing the UI (like Windows).
    private let showDelay: TimeInterval = 0.12

    init() {
        panels.onHover = { [weak self] i in self?.select(i) }
        panels.onClick = { [weak self] i in
            guard let self else { return }
            self.select(i)
            self.finish()
        }
        panels.onRightClick = { [weak self] i, event in
            self?.select(i)
            self?.showTilingMenu(at: event.screenLocation)
        }
        panels.onPreviewHover = { [weak self] i in
            if self?.grouped == true { self?.previews.select(i) }
        }
        // A preview is of the selected window (or, grouped, the one clicked), so clicking it switches there.
        panels.onPreviewClick = { [weak self] i in
            guard let self else { return }
            if self.grouped { self.previews.select(i) }
            self.finish()
        }
        panels.onPreviewRightClick = { [weak self] i, event in
            guard let self else { return }
            if self.grouped { self.previews.select(i) }
            self.showTilingMenu(at: event.screenLocation)
        }
    }

    // MARK: - What's shown

    /// The windows grouped by app, in the order of each app's most recent window (so each group's first is it).
    private var appGroups: [[SwitcherWindow]] {
        var order: [pid_t] = []
        var byApp: [pid_t: [SwitcherWindow]] = [:]
        for w in windows {
            let pid = w.app.processIdentifier
            if byApp[pid] == nil { order.append(pid) }
            byApp[pid, default: []].append(w)
        }
        return order.map { byApp[$0]! }
    }

    private var tileCount: Int { grouped ? appGroups.count : windows.count }

    /// The window a switch, W or M acts on: the highlighted preview's, or else the selected tile's (grouped: the app's
    /// most recent window).
    private var targetWindow: SwitcherWindow? {
        guard grouped else { return windows.indices.contains(selected) ? windows[selected] : nil }
        if let window = previews.selectedWindow { return window }
        let groups = appGroups
        return groups.indices.contains(selected) ? groups[selected].first : nil
    }

    /// In icon view, a preview of the selected window can hang below its icon, like the Dock's window previews.
    private var showsPreview: Bool { !Settings.showThumbnails && Settings.switcherPreviews }

    private func showPanels() {
        let tiles: [SwitcherTile]
        if grouped {
            tiles = appGroups.map { group in
                let app = group[0].app
                let name = app.localizedName ?? group[0].title
                return SwitcherTile(icon: app.icon ?? NSImage(), name: name, title: name,
                                    isMinimized: group.allSatisfy(\.isMinimized), isAppHidden: group[0].isAppHidden)
            }
        } else {
            // An app's name doesn't tell its windows apart, so apps with several windows listed show the window title.
            var windowCounts: [pid_t: Int] = [:]
            for w in windows { windowCounts[w.app.processIdentifier, default: 0] += 1 }
            tiles = windows.map { SwitcherTile(window: $0, nameByTitle: windowCounts[$0.app.processIdentifier, default: 0] > 1) }
        }
        // App icons are the same size as in the Option+Tab Dock. Grouped, it's always app icons (with the selected
        // app's window thumbnails below), even in thumbnail view.
        let thumbnails = Settings.showThumbnails && !grouped
        let dock = thumbnails ? [] : DockItems.current()
        panels.show(tiles: tiles, selected: selected, thumbnails: thumbnails,
                    iconsLikeDock: thumbnails ? nil : (dock.count, dock.filter(\.dividerBefore).count))
        updatePreviews()
    }

    /// The selected app's windows (grouped), or the selected window (with Show Window Preview), under its tile.
    /// `keepHighlight` keeps the highlighted preview, if it's still there.
    private func updatePreviews(keepHighlight: Bool = true) {
        guard panels.isVisible else { return previews.clear() }
        if grouped {
            let groups = appGroups
            let highlight = keepHighlight ? previews.selected : nil
            previews.show(groups.indices.contains(selected) ? groups[selected] : [], under: selected,
                          selected: highlight, refreshThumbnails: false)
        } else if showsPreview, windows.indices.contains(selected) {
            previews.show([windows[selected]], under: selected, refreshThumbnails: false)
        } else {
            previews.clear()
        }
    }

    /// Snapshots of every window, for thumbnails and previews, taken once per session.
    private func requestThumbnails() {
        guard !thumbnailsRequested else { return }
        thumbnailsRequested = true
        Thumbnails.shared.retain(only: windows.map(\.id))
        Thumbnails.shared.refresh(windows.map(\.id)) { [weak self] id, image in
            guard let self, self.running else { return }
            self.panels.setThumbnail(image, for: id)
            self.panels.setPreviewThumbnail(image, for: id)
        }
    }

    // MARK: - Session

    func begin(backwards: Bool) {
        running = true
        grouped = false
        thumbnailsRequested = false
        windows = WindowManager.shared.currentWindows()
        guard !windows.isEmpty else { return }
        selected = backwards ? windows.count - 1 : min(1, windows.count - 1)
        if Settings.showThumbnails || showsPreview { requestThumbnails() }

        let work = DispatchWorkItem { [weak self] in self?.showNow() }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    /// Tab / Shift+Tab: the next or previous tile, leaving the previews.
    func move(_ delta: Int) {
        guard running, tileCount > 0 else { return }
        select(wrapped(selected, by: delta, count: tileCount))
        showNow()
    }

    /// Left / Right: between previews while in them (grouped), otherwise between tiles.
    func moveHorizontal(_ delta: Int) {
        guard running else { return }
        if grouped && previews.selected != nil { return previews.move(delta) }
        move(delta)
    }

    /// Down: into the selected app's previews (grouped), or the row below.
    func moveDown() {
        guard running else { return }
        if grouped {
            guard previews.selected == nil else { return }
            if !previews.isEmpty { return previews.select(0) }
        }
        moveRow(1)
    }

    /// Up: from the previews back to the icons (grouped), or the row above.
    func moveUp() {
        guard running else { return }
        if grouped && previews.selected != nil { return previews.select(nil) }
        moveRow(-1)
    }

    private func moveRow(_ delta: Int) {
        guard running, tileCount > 0 else { return }
        if let target = movedRows(selected, by: delta, columns: panels.columns, count: tileCount) { select(target) }
        showNow()
    }

    /// G: one tile per app, or per window again. Keeps the same window (or its app) selected.
    func toggleGrouping() {
        guard running, !windows.isEmpty else { return }
        let target = targetWindow
        grouped.toggle()
        if grouped {
            selected = appGroups.firstIndex { group in group.contains { $0.id == target?.id } } ?? 0
            requestThumbnails()
        } else {
            selected = windows.firstIndex { $0.id == target?.id } ?? 0
        }
        previews.clear()
        redraw()
    }

    func commit() {
        guard running else { return }
        let target = targetWindow
        reset()
        if let target { WindowManager.shared.focus(target) }
    }

    func cancel() {
        reset()
    }

    /// No windows to switch between (begin() then shows nothing).
    var isEmpty: Bool { windows.isEmpty }

    /// Switches by some route other than releasing Cmd.
    private func finish() {
        commit()
        onFinished?()
    }

    // MARK: - Actions on the selected window or app

    /// Cmd+W: close the selected window and keep the switcher open.
    func closeSelected() {
        guard running, let target = targetWindow else { return }
        if WindowManager.shared.close(target) {
            remove { $0.id == target.id }
        } else {
            NSSound.beep()
        }
    }

    /// Cmd+Q: quit the selected window's app and keep the switcher open.
    func quitSelected() {
        guard running, let app = targetWindow?.app else { return }
        if WindowManager.shared.quit(app) {
            remove { $0.app.processIdentifier == app.processIdentifier }
        } else {
            NSSound.beep()
        }
    }

    /// Cmd+M: minimize the selected window, or restore it if it's already minimized.
    func toggleMinimizeSelected() {
        guard running, let target = targetWindow, let i = windows.firstIndex(where: { $0.id == target.id }) else { return }
        guard WindowManager.shared.toggleMinimized(target) else { return NSSound.beep() }
        windows[i].isMinimized.toggle()
        // Restoring a window of a hidden app unhid the app too, so the badges end up in a clear state.
        if target.isMinimized && target.isAppHidden {
            let pid = target.app.processIdentifier
            for j in windows.indices where windows[j].app.processIdentifier == pid { windows[j].isAppHidden = false }
        }
        scheduleSync()
        if windows[i].isMinimized && !Settings.includeMinimized {
            remove { $0.id == target.id }
        } else {
            redraw()
        }
    }

    /// Cmd+H: hide the selected window's app, or unhide it if it's already hidden.
    func toggleHideSelected() {
        guard running, let target = targetWindow else { return }
        let pid = target.app.processIdentifier
        let hide = !target.isAppHidden
        WindowManager.shared.setHidden(target.app, hide)
        for i in windows.indices where windows[i].app.processIdentifier == pid { windows[i].isAppHidden = hide }
        scheduleSync()
        if hide && !Settings.includeHiddenApps {
            remove { $0.app.processIdentifier == pid }
        } else {
            redraw()
        }
    }

    /// Cmd+?: shows or hides the list of keys and mouse actions.
    func toggleHelp() {
        guard running, !windows.isEmpty else { return }
        showNow()
        panels.toggleHelp(title: KeyHelp.switcherTitle, rows: KeyHelp.switcher)
    }

    /// Cmd+N: a new window of the selected window's app, through its "New Window" menu item. The switcher closes and
    /// the app comes forward with it; an app without that item beeps, and the switcher stays.
    func newWindowForSelected() {
        guard running, let app = targetWindow?.app else { return }
        guard WindowManager.shared.newWindow(of: app) else { return NSSound.beep() }
        reset()
        onFinished?()
    }

    /// Cmd+T: the tiling menu for the selected window, at its tile (or highlighted preview).
    func showTilingMenuForSelected() {
        guard running, !windows.isEmpty else { return }
        showNow()
        let frame = grouped && previews.selected != nil
            ? panels.tileScreenFrame(previews.selected!, preview: true)
            : panels.tileScreenFrame(selected)
        guard let frame else { return NSSound.beep() }
        showTilingMenu(at: NSPoint(x: frame.minX, y: frame.minY))
    }

    /// Right-click or T: the green button's layouts (Fill, halves, ...) for the selected window, at `point` (screen
    /// coordinates). Choosing one applies it and switches to the window; closing the menu after Cmd was let go
    /// switches too, as letting go would have.
    private func showTilingMenu(at point: NSPoint) {
        guard running, let target = targetWindow else { return }
        let menu = WindowTiling.menu(for: target, others: windows) { [weak self] in self?.finish() }
        menuOpen = true
        menu.popUp(positioning: nil, at: point, in: nil)
        menuOpen = false
        // Ask the keyboard itself: keys passed to the menu had Cmd taken out (see HotkeyTap), so the session's view of
        // the modifiers (and the last event's) says it was let go even while it's still held.
        if running && !CGEventSource.flagsState(.hidSystemState).contains(.maskCommand) { finish() }
    }

    // MARK: - State

    /// The toggles update tiles optimistically, but macOS may do more (some apps unhide when a window is
    /// un-minimized) and hide/unhide apply asynchronously. Re-read the real state once things settle.
    private func scheduleSync() {
        afterEach([0.3, 1.0]) { [weak self] in self?.syncStates() }
    }

    private func syncStates() {
        guard running else { return }
        var changed = false
        var hiddenByPid: [pid_t: Bool] = [:]
        let onScreen = WindowManager.shared.onScreenWindowIDs()
        for i in windows.indices {
            let app = windows[i].app
            // Ask the app via Accessibility; NSRunningApplication.isHidden can lag behind.
            let hidden = hiddenByPid[app.processIdentifier] ?? {
                let value = AX.bool(AXUIElementCreateApplication(app.processIdentifier), kAXHiddenAttribute) ?? app.isHidden
                hiddenByPid[app.processIdentifier] = value
                return value
            }()
            let minimized = WindowManager.shared.isMinimized(windows[i].element, id: windows[i].id, onScreen: onScreen)
                ?? windows[i].isMinimized
            if hidden != windows[i].isAppHidden || minimized != windows[i].isMinimized {
                windows[i].isAppHidden = hidden
                windows[i].isMinimized = minimized
                changed = true
            }
        }
        if changed { redraw() }
    }

    private func remove(where shouldRemove: (SwitcherWindow) -> Bool) {
        windows.removeAll(where: shouldRemove)
        guard !windows.isEmpty else { return reset() }
        selected = min(selected, tileCount - 1)
        redraw()
    }

    /// Re-lays out the grid after windows were removed or changed state, keeping the order and selection.
    private func redraw() {
        showPanels()
        pendingShow?.cancel()
        pendingShow = nil
    }

    private func select(_ i: Int) {
        guard (0..<tileCount).contains(i) else { return }
        selected = i
        panels.setSelected(i)
        if panels.isVisible { updatePreviews(keepHighlight: false) }
    }

    private func showNow() {
        pendingShow?.cancel()
        pendingShow = nil
        guard running, !windows.isEmpty, !panels.isVisible else { return }
        showPanels()
        // The first time the switcher ever appears, its help comes with it.
        if !Settings.switcherHelpShown {
            Settings.switcherHelpShown = true
            panels.toggleHelp(title: KeyHelp.switcherTitle, rows: KeyHelp.switcher)
        }
    }

    private func reset() {
        running = false
        grouped = false
        pendingShow?.cancel()
        pendingShow = nil
        previews.clear()
        panels.dismiss()
        windows = []
        Thumbnails.shared.endSession()
    }
}
