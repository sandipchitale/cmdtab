import AppKit

/// State machine for one Cmd+Tab session: begin -> move* -> commit | cancel.
@MainActor
final class SwitcherController {
    private let panels = PanelGroup()
    /// Every window listed, most recently used first.
    private var allWindows: [SwitcherWindow] = []
    /// What's typed in the search (F), or nil while there's none.
    private var query: String?
    /// Keys typed after the search stopped matching: shown in red after it and not searched for, until Delete takes
    /// them back. (Dropping them instead would let a later key turn the search into a word that wasn't typed.)
    private var refused = ""
    /// Keys type into the search, or (read-only, after Esc) they're commands, with what it found kept.
    private var typing = false
    private var searchState: SearchState? { query == nil ? nil : typing ? .typing : .readOnly }
    /// The windows shown: every one, or while searching, those that match.
    private var windows: [SwitcherWindow] {
        guard let query else { return allWindows }
        return allWindows.filter { Search.rank(query, in: Self.searchFields($0)) != nil }
    }
    /// The selected tile: a window, or (grouped) an app.
    private var selected = 0
    private var pendingShow: DispatchWorkItem?
    private var running = false
    /// G: one tile per app instead of per window, with the selected app's windows previewed under it. Remembered for
    /// the next Cmd+Tab (`Settings.switcherGrouped`).
    private var grouped = false
    /// The single-window preview, or (grouped) the selected app's windows.
    private lazy var previews = WindowPreviews(panels: panels)
    private var thumbnailsRequested = false
    /// Z: instead of the windows, the running apps that have none, to quit them (or open them); nil while it's the
    /// windows.
    private var windowlessApps: [NSRunningApplication]?
    /// The window selected when Z showed the apps, selected again when the windows come back.
    private var windowBeforeApps: SwitcherWindow?
    /// Kept open after Cmd is let go (K, ⌃⌥Tab, X from the Dock, or a search put away then): the bubble says so.
    private var keptOpen = false
    /// The tip the bubble shows this time: one of the first few times the switcher appears teaches a key.
    private var tip: (title: String, hint: String)?

    /// True while a tile's tiling menu is tracking; releasing Cmd doesn't switch then.
    private(set) var menuOpen = false

    /// Called when a switch finishes by some route other than releasing Cmd (mouse click, tiling menu).
    var onFinished: (() -> Void)?
    /// Called when the search begins, turns read-only or goes, so the keyboard's handling can follow.
    var onSearchChanged: ((SearchState?) -> Void)?

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
        panels.onSearchClear = { [weak self] in self?.clearSearch() }
        panels.onWindowButton = { [weak self] i, button in
            self?.select(i)
            self?.press(button)
        }
        panels.onPreviewWindowButton = { [weak self] i, button in
            guard let self else { return }
            if self.grouped { self.previews.select(i) }
            self.press(button)
        }
    }

    /// A hover button on a tile or a preview, for the window it's on (which is selected by now).
    private func press(_ button: WindowButton) {
        switch button {
        case .close: closeSelected()
        case .minimize: toggleMinimizeSelected()
        case .fill: fillSelected()
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

    private var tileCount: Int { windowlessApps?.count ?? (grouped ? appGroups.count : windows.count) }

    /// The window a switch, W or M acts on: the highlighted preview's, or else the selected tile's (grouped: the app's
    /// most recent window).
    private var targetWindow: SwitcherWindow? {
        guard windowlessApps == nil else { return nil }
        guard grouped else { return windows.indices.contains(selected) ? windows[selected] : nil }
        if let window = previews.selectedWindow { return window }
        let groups = appGroups
        return groups.indices.contains(selected) ? groups[selected].first : nil
    }

    /// In icon view, a preview of the selected window can hang below its icon, like the Dock's window previews.
    private var showsPreview: Bool { !Settings.showThumbnails && Settings.switcherPreviews }

    private func showPanels() {
        let tiles: [SwitcherTile]
        if let windowlessApps {
            tiles = windowlessApps.map { app in
                let name = app.localizedName ?? app.bundleIdentifier ?? "App"
                return SwitcherTile(icon: app.icon ?? NSImage(), name: name, title: name, isAppHidden: app.isHidden, isRunning: true)
            }
        } else if grouped {
            tiles = appGroups.map { group in
                let app = group[0].app
                let name = app.localizedName ?? group[0].title
                // In thumbnail view, the app's tile shows its most recent window.
                return SwitcherTile(icon: app.icon ?? NSImage(), name: name, title: name,
                                    isMinimized: group.allSatisfy(\.isMinimized), isAppHidden: group[0].isAppHidden,
                                    windowID: group[0].id)
            }
        } else {
            // An app's name doesn't tell its windows apart, so apps with several windows listed show the window title.
            var windowCounts: [pid_t: Int] = [:]
            for w in windows { windowCounts[w.app.processIdentifier, default: 0] += 1 }
            tiles = windows.map { SwitcherTile(window: $0, nameByTitle: windowCounts[$0.app.processIdentifier, default: 0] > 1) }
        }
        // App icons in the grid are the same size as in the Option+Tab Dock. Z's apps are always icons.
        let thumbnails = Settings.showThumbnails && windowlessApps == nil
        let dock = thumbnails || Settings.ring ? nil : DockItems.current()
        // While searching, tiles keep the size they have with every window shown.
        panels.show(tiles: tiles, selected: selected, thumbnails: thumbnails,
                    iconsLikeDock: dock.map { ($0.count, $0.filter(\.dividerBefore).count) },
                    sizingCount: query == nil ? nil : allTileCount)
        panels.setSearch(bubbleText)
        updatePreviews()
    }

    /// How many tiles there are with nothing searched for: windows, or grouped, apps.
    private var allTileCount: Int { grouped ? Set(allWindows.map(\.app.processIdentifier)).count : allWindows.count }

    /// What the bubble over the panel shows: Z's label, the search, that the switcher is kept open, or a tip.
    private var bubbleText: PanelGroup.SearchText? {
        if windowlessApps != nil {
            return ("", "Apps with no windows", "Q to quit · Return to open · Z for windows", false, "app.dashed", "")
        }
        if let searchText { return searchText }
        if keptOpen { return ("", "Kept open", "Return to switch · Esc to cancel", false, "pin", "") }
        return tip.map { ("", $0.title, $0.hint, false, "lightbulb", "") }
    }

    /// The search bubble's text, or nil while there's no search.
    private var searchText: PanelGroup.SearchText? {
        guard let query else { return nil }
        let found = "\(tileCount) of \(allTileCount)"
        if !typing {
            return (query, "Search cleared", query.isEmpty ? "F to type · Esc to close" : "\(found) · F to edit · ⌫ to clear",
                    false, "magnifyingglass", "")
        }
        let hint = !refused.isEmpty ? "No match · ⌫ to delete" : query.isEmpty ? "Esc to close" : "\(found) · Return to switch · Esc for keys"
        return (query, grouped ? "Type to find an app or window" : "Type to find a window", hint, true, "magnifyingglass", refused)
    }

    /// Says why a key did nothing, in place of a beep: a notice that fades away where the selected tile's name goes
    /// (bringing the switcher up first, if it isn't yet).
    func showNotice(_ text: String) {
        showNow()
        panels.showNotice(text)
    }

    /// Whether the switcher is kept open without Cmd held (K, ⌃⌥Tab, X from the Dock, or a search put away then).
    func setKeptOpen(_ kept: Bool) {
        guard kept != keptOpen else { return }
        keptOpen = kept
        if panels.isVisible { panels.setSearch(bubbleText) }
    }

    /// What the search looks in: the window's app name and its title.
    private static func searchFields(_ window: SwitcherWindow) -> [String] {
        [window.app.localizedName ?? "", window.title]
    }

    /// The tile showing `window`: its own, or grouped, its app's.
    private func tileIndex(of window: SwitcherWindow?) -> Int? {
        guard let window else { return nil }
        if grouped { return appGroups.firstIndex { group in group.contains { $0.id == window.id } } }
        return windows.firstIndex { $0.id == window.id }
    }

    /// The selected app's windows (grouped), or the selected window (with Show Window Preview), under its tile.
    /// `keepHighlight` keeps the highlighted preview, if it's still there.
    private func updatePreviews(keepHighlight: Bool = true) {
        guard panels.isVisible, windowlessApps == nil else { return previews.clear() }
        if grouped {
            let groups = appGroups
            let highlight = keepHighlight ? previews.selected : nil
            var group = groups.indices.contains(selected) ? groups[selected] : []
            // In thumbnail view, an app with one window already shows it in its tile.
            if Settings.showThumbnails && group.count == 1 { group = [] }
            previews.show(group, under: selected, selected: highlight, refreshThumbnails: false)
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
        // Every window, not just those a search shows, so they're ready when it widens.
        Thumbnails.shared.retain(only: allWindows.map(\.id))
        Thumbnails.shared.refresh(allWindows.map(\.id)) { [weak self] id, image in
            guard let self, self.running else { return }
            self.panels.setThumbnail(image, for: id)
            self.panels.setPreviewThumbnail(image, for: id)
        }
    }

    // MARK: - Session

    func begin(backwards: Bool) {
        running = true
        grouped = Settings.switcherGrouped
        thumbnailsRequested = false
        allWindows = WindowManager.shared.currentWindows()
        guard !allWindows.isEmpty else { return }
        // The previous window, or grouped, the previous app (as the native switcher does).
        selected = backwards ? tileCount - 1 : min(1, tileCount - 1)
        if grouped || Settings.showThumbnails || showsPreview { requestThumbnails() }

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

    /// Z: the running apps with no windows instead of the windows, to quit them with Q (or open one with Return), or
    /// the windows again, with the one selected before still selected. A search goes first; if there are no such
    /// apps, a notice says so.
    func toggleWindowlessApps() {
        guard running, !allWindows.isEmpty else { return }
        if windowlessApps != nil { return showWindowsAgain() }
        let apps = WindowManager.shared.windowlessApps(listed: Set(allWindows.map(\.app.processIdentifier)))
        guard !apps.isEmpty else { return showNotice(Notice.noWindowlessApps) }
        if query != nil { endSearch() }
        windowBeforeApps = targetWindow
        windowlessApps = apps
        selected = 0
        previews.clear()
        redraw()
    }

    private func showWindowsAgain() {
        windowlessApps = nil
        selected = tileIndex(of: windowBeforeApps) ?? 0
        windowBeforeApps = nil
        redraw()
    }

    /// The app selected among Z's, if they're shown.
    private var selectedApp: NSRunningApplication? {
        windowlessApps.flatMap { $0.indices.contains(selected) ? $0[selected] : nil }
    }

    /// G: one tile per app, or per window again. Keeps the same window (or its app) selected.
    func toggleGrouping() {
        guard running, !windows.isEmpty else { return }
        guard windowlessApps == nil else { return showNotice(Notice.groupAmongApps) }
        let target = targetWindow
        grouped.toggle()
        Settings.switcherGrouped = grouped
        selected = tileIndex(of: target) ?? 0
        if grouped { requestThumbnails() }
        previews.clear()
        redraw()
    }

    /// .: app icons or window thumbnails, the same setting as the menu bar menu's, so it sticks for the next Cmd+Tab.
    /// Grouped, the highlighted preview stays highlighted.
    func toggleThumbnails() {
        guard running, !windows.isEmpty else { return }
        guard windowlessApps == nil else { return showNotice(Notice.viewAmongApps) }
        Settings.showThumbnails.toggle()
        if Settings.showThumbnails || showsPreview { requestThumbnails() }
        redraw()
    }

    /// R: tiles around a big ring, or the grid again. Shared with the Dock and saved, so X keeps the ring. Unless it's
    /// turned on in the menu, a notice says where.
    func toggleRing() {
        guard running, !windows.isEmpty else { return }
        guard Settings.ringEnabled else { return showNotice(Notice.ringOff) }
        Settings.ringLayout.toggle()
        redraw()
    }

    /// Letting go of Cmd: switch to the selected window. Among Z's apps, nothing is switched to; you stay where you were.
    func commit() {
        guard running else { return }
        let target = targetWindow
        reset()
        if let target { WindowManager.shared.focus(target) }
    }

    /// Return or a click: switch to the selected window, or open the selected one of Z's apps, as the Dock would.
    func choose() {
        guard let app = selectedApp else { return commit() }
        reset()
        WindowManager.shared.open(app)
    }

    func cancel() {
        reset()
    }

    /// No windows to switch between (begin() then shows nothing).
    var isEmpty: Bool { allWindows.isEmpty }

    /// Switches by some route other than releasing Cmd.
    private func finish() {
        choose()
        onFinished?()
    }

    // MARK: - Actions on the selected window or app

    /// Cmd+W: close the selected window and keep the switcher open. Its tile goes at once, but if the window is still
    /// there a moment later (its app is asking something, such as whether to save), the tile comes back.
    func closeSelected() {
        guard running else { return }
        guard windowlessApps == nil else { return showNotice(Notice.noWindowsAmongApps) }
        guard let target = targetWindow else { return }
        switch WindowManager.shared.close(target) {
        case .noButton:
            showNotice(Notice.cantClose)
        case .pressed:
            let index = allWindows.firstIndex { $0.id == target.id }
            remove { $0.id == target.id }
            confirmClosed(target, at: index)
        case .noAnswer:
            confirmClosed(target, at: nil)
        }
    }

    /// A moment after W pressed `window`'s close button: if it's still there, its app is asking something (or wouldn't
    /// close it). Its tile comes back (at `index` in the list, if it went), selected unless the selection has moved on
    /// since, so letting go goes to the question, and a notice says so. If the window is gone, so is its tile.
    private func confirmClosed(_ window: SwitcherWindow, at index: Int?) {
        let selectedAfterClose = selected
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.running else { return }
            let listed = self.allWindows.contains { $0.id == window.id }
            guard WindowManager.shared.exists(window.id) else {
                // Closed after all, only slowly.
                if listed { self.remove { $0.id == window.id } }
                return
            }
            guard listed || index != nil else { return }
            if !listed, let index { self.allWindows.insert(window, at: min(index, self.allWindows.count)) }
            if self.selected == selectedAfterClose, let i = self.tileIndex(of: window) { self.selected = i }
            self.redraw()
            self.showNotice(Notice.notClosed(window.app))
            // If it closes after all (its app was slow, or got its answer), its tile goes then.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.running, !WindowManager.shared.exists(window.id),
                      self.allWindows.contains(where: { $0.id == window.id }) else { return }
                self.remove { $0.id == window.id }
            }
        }
    }

    /// Cmd+Q: quit the selected window's app and keep the switcher open.
    func quitSelected() {
        guard running else { return }
        if let app = selectedApp { return quitWindowless(app) }
        guard let app = targetWindow?.app else { return }
        if WindowManager.shared.quit(app) {
            remove { $0.app.processIdentifier == app.processIdentifier }
        } else {
            showNotice(Notice.cantQuit(app))
        }
    }

    /// Q among Z's apps: quit it, and the switcher stays; once none are left, the windows come back.
    private func quitWindowless(_ app: NSRunningApplication) {
        guard WindowManager.shared.quit(app) else { return showNotice(Notice.cantQuit(app)) }
        windowlessApps?.removeAll { $0.processIdentifier == app.processIdentifier }
        if windowlessApps?.isEmpty ?? true { return showWindowsAgain() }
        selected = min(selected, tileCount - 1)
        redraw()
    }

    /// Cmd+M: minimize the selected window, or restore it if it's already minimized.
    func toggleMinimizeSelected() {
        guard running else { return }
        guard windowlessApps == nil else { return showNotice(Notice.noWindowsAmongApps) }
        guard let target = targetWindow, let i = allWindows.firstIndex(where: { $0.id == target.id }) else { return }
        guard WindowManager.shared.toggleMinimized(target) else { return showNotice(Notice.cantMinimize(restoring: target.isMinimized)) }
        allWindows[i].isMinimized.toggle()
        // Restoring a window of a hidden app unhid the app too, so the badges end up in a clear state.
        if target.isMinimized && target.isAppHidden {
            let pid = target.app.processIdentifier
            for j in allWindows.indices where allWindows[j].app.processIdentifier == pid { allWindows[j].isAppHidden = false }
        }
        scheduleSync()
        if allWindows[i].isMinimized && !Settings.includeMinimized {
            remove { $0.id == target.id }
        } else {
            redraw()
        }
    }

    /// A tile's green button: fill the screen with the window (or put it back), and switch to it, as the tiling menu's
    /// Fill does.
    private func fillSelected() {
        guard running, windowlessApps == nil, let target = targetWindow else { return }
        WindowTiling.toggleFill(target)
        finish()
    }

    /// Cmd+H: hide the selected window's app, or unhide it if it's already hidden.
    func toggleHideSelected() {
        guard running else { return }
        if let app = selectedApp {
            WindowManager.shared.setHidden(app, !app.isHidden)
            // Hiding applies a moment later; then the badge follows.
            return afterEach([0.3, 1.0]) { [weak self] in if self?.windowlessApps != nil { self?.redraw() } }
        }
        guard let target = targetWindow else { return }
        let pid = target.app.processIdentifier
        let hide = !target.isAppHidden
        WindowManager.shared.setHidden(target.app, hide)
        for i in allWindows.indices where allWindows[i].app.processIdentifier == pid { allWindows[i].isAppHidden = hide }
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
        panels.toggleHelp(title: KeyHelp.switcherTitle, sections: KeyHelp.switcher)
    }

    /// Cmd+N: a new window of the selected window's app, through its "New Window" menu item. The switcher closes and
    /// the app comes forward with it; for an app without that item, a notice says so, and the switcher stays.
    func newWindowForSelected() {
        guard running else { return }
        // One of Z's apps opens, which for most apps with no windows makes one.
        if selectedApp != nil { return finish() }
        guard let app = targetWindow?.app else { return }
        guard WindowManager.shared.newWindow(of: app) else { return showNotice(Notice.noNewWindow(app)) }
        reset()
        onFinished?()
    }

    /// Cmd+T: the tiling menu for the selected window, at its tile (or highlighted preview).
    func showTilingMenuForSelected() {
        guard running, !windows.isEmpty else { return }
        guard windowlessApps == nil else { return showNotice(Notice.noWindowsAmongApps) }
        showNow()
        let frame = grouped && previews.selected != nil
            ? panels.tileScreenFrame(previews.selected!, preview: true)
            : panels.tileScreenFrame(selected)
        guard let frame else { return }
        showTilingMenu(at: NSPoint(x: frame.minX, y: frame.minY))
    }

    /// Right-click or T: the green button's layouts (Fill, halves, ...) for the selected window, at `point` (screen
    /// coordinates). Choosing one applies it and switches to the window; closing the menu after Cmd was let go
    /// switches too, as letting go would have (but not while searching, when letting go doesn't switch).
    private func showTilingMenu(at point: NSPoint) {
        guard running, let target = targetWindow else { return }
        // Arrangements place the next most recent windows, whether or not the search shows them.
        let menu = WindowTiling.menu(for: target, others: allWindows) { [weak self] in self?.finish() }
        menuOpen = true
        menu.popUp(positioning: nil, at: point, in: nil)
        menuOpen = false
        // Ask the keyboard itself: keys passed to the menu had Cmd taken out (see HotkeyTap), so the session's view of
        // the modifiers (and the last event's) says it was let go even while it's still held.
        if running && query == nil && !CGEventSource.flagsState(.hidSystemState).contains(.maskCommand) { finish() }
    }

    // MARK: - Search (F)

    /// F: type into the search, a new one (every tile stays until something is typed) or the read-only one there.
    /// Among Z's apps, the windows come back to be searched. False if there's nothing to search.
    func beginSearch() -> Bool {
        guard running, !allWindows.isEmpty else { return false }
        if windowlessApps != nil { showWindowsAgain() }
        if query == nil { query = "" }
        typing = true
        onSearchChanged?(.typing)
        if panels.isVisible { panels.setSearch(bubbleText) } else { showNow() }
        return true
    }

    /// A key typed into the search: adds `text` to it if anything still matches. If nothing does, it's refused: it
    /// shows in red after the search, and so do the keys after it, until they're deleted.
    func type(_ text: String) {
        guard running, typing, let query else { return }
        if refused.isEmpty && search(query + text) { return }
        refused += text
        panels.setSearch(bubbleText)
    }

    /// Delete: the last refused key, or else the search's last character.
    func deleteBackward() {
        guard running, typing, let query else { return }
        if !refused.isEmpty {
            refused.removeLast()
            return panels.setSearch(bubbleText)
        }
        guard !query.isEmpty else { return }
        search(String(query.dropLast()))
    }

    /// Cmd+Delete (Delete when read-only), or the search's clear button: the search empties, and every window is
    /// back, with the selection kept. The search stays.
    func clearSearch() {
        guard running, let query, !query.isEmpty || !refused.isEmpty else { return }
        refused = ""
        search("")
    }

    /// Esc with a search: typing stops and what it found stays (read-only), so keys are commands again; an empty
    /// search goes. False, doing nothing, for a read-only one with something in it (Esc then cancels, as usual) or
    /// with no search.
    func escapeSearch() -> Bool {
        guard running, let query else { return false }
        if query.isEmpty {
            endSearch()
        } else if typing {
            typing = false
            // Read-only, it's what was found that counts.
            refused = ""
            panels.setSearch(bubbleText)
            onSearchChanged?(.readOnly)
        } else {
            return false
        }
        return true
    }

    /// The search goes, and every window is back, with the one found still selected.
    private func endSearch() {
        let target = targetWindow
        query = nil
        refused = ""
        typing = false
        selected = tileIndex(of: target) ?? 0
        previews.clear()
        redraw()
        onSearchChanged?(nil)
    }

    /// Shows the windows matching `text` and selects the best match (for an empty search, the one already selected).
    /// False, changing nothing, if nothing matches.
    @discardableResult
    private func search(_ text: String) -> Bool {
        let current = targetWindow
        let ranked = allWindows.compactMap { w in Search.rank(text, in: Self.searchFields(w)).map { (window: w, rank: $0) } }
        // The first of the best, so ties go to the most recently used.
        guard let best = ranked.min(by: { $0.rank < $1.rank })?.window else { return false }
        query = text
        selected = tileIndex(of: text.isEmpty ? current : best) ?? 0
        previews.clear()
        redraw()
        return true
    }

    // MARK: - State

    /// The toggles update tiles optimistically, but macOS may do more (some apps unhide when a window is
    /// un-minimized) and hide/unhide apply asynchronously. Re-read the real state once things settle: a window still
    /// counts as on screen until its minimize animation is over, so an earlier read would undo the badge.
    private func scheduleSync() {
        afterEach([0.5, 1.2]) { [weak self] in self?.syncStates() }
    }

    private func syncStates() {
        guard running else { return }
        var changed = false
        var hiddenByPid: [pid_t: Bool] = [:]
        let onScreen = WindowManager.shared.onScreenWindowIDs()
        for i in allWindows.indices {
            let app = allWindows[i].app
            // Ask the app via Accessibility; NSRunningApplication.isHidden can lag behind.
            let hidden = hiddenByPid[app.processIdentifier] ?? {
                let value = AX.bool(AXUIElementCreateApplication(app.processIdentifier), kAXHiddenAttribute) ?? app.isHidden
                hiddenByPid[app.processIdentifier] = value
                return value
            }()
            let minimized = WindowManager.shared.isMinimized(allWindows[i].element, id: allWindows[i].id, onScreen: onScreen)
                ?? allWindows[i].isMinimized
            if hidden != allWindows[i].isAppHidden || minimized != allWindows[i].isMinimized {
                allWindows[i].isAppHidden = hidden
                allWindows[i].isMinimized = minimized
                changed = true
            }
        }
        if changed { redraw() }
    }

    private func remove(where shouldRemove: (SwitcherWindow) -> Bool) {
        allWindows.removeAll(where: shouldRemove)
        guard !allWindows.isEmpty else {
            let searching = query != nil
            reset()
            // A search kept the switcher up without Cmd; with nothing left, it goes.
            if searching { onSearchChanged?(nil) }
            return
        }
        // Nothing left that the search found: it goes, and every window is back.
        if query != nil && windows.isEmpty {
            query = nil
            refused = ""
            typing = false
            onSearchChanged?(nil)
        }
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
        // The first time the switcher ever appears, its help comes with it; the next few times, a tip in the bubble.
        let firstTime = !Settings.switcherHelpShown
        if !firstTime, Settings.switcherTipsShown < KeyHelp.switcherTips.count {
            tip = KeyHelp.switcherTips[Settings.switcherTipsShown]
            Settings.switcherTipsShown += 1
        }
        showPanels()
        if firstTime {
            Settings.switcherHelpShown = true
            panels.toggleHelp(title: KeyHelp.switcherTitle, sections: KeyHelp.switcher)
        }
    }

    private func reset() {
        running = false
        grouped = false
        query = nil
        refused = ""
        keptOpen = false
        tip = nil
        typing = false
        windowlessApps = nil
        windowBeforeApps = nil
        pendingShow?.cancel()
        pendingShow = nil
        previews.clear()
        panels.dismiss()
        allWindows = []
        Thumbnails.shared.endSession()
    }
}
