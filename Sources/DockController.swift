import AppKit

/// The Option+Tab Dock: a Dock-like row of apps, folders and the Trash that stays up until you pick something, press
/// Esc or Option+Tab, or click outside it.
@MainActor
final class DockController {
    private let panels = PanelGroup()
    /// Every item in the Dock, in its order.
    private var allItems: [DockItem] = []
    /// What's typed in the search (F), or nil while there's none.
    private var query: String?
    /// Keys typed after the search stopped matching: shown in red after it and not searched for, until Delete takes
    /// them back. (Dropping them instead would let a later key turn the search into a word that wasn't typed.)
    private var refused = ""
    /// Keys type into the search, or (read-only, after Esc) they're the Dock's commands, with what it found kept.
    private var typing = false
    /// The tip the bubble shows this time: one of the first few times the Dock appears teaches a key.
    private var tip: (title: String, hint: String)?
    private var selected = 0
    /// Z: the running apps with no windows, which are all the Dock shows then; nil while it shows every item.
    private var windowlessPIDs: Set<pid_t>?
    /// The item selected when Z narrowed the Dock, selected again when every item comes back.
    private var itemBeforeWindowless: DockItem?
    /// How small the icons may get to keep the Dock one row: as small as the real Dock draws its own (it shrinks them
    /// when it's crowded), and otherwise 36. Read each time the Dock opens.
    private var smallestRowSide: CGFloat = 36

    /// The items shown: every one, or while searching, those that match, with a divider between two from different
    /// sections; or with Z, just the apps with no windows.
    private var items: [DockItem] {
        if let windowlessPIDs {
            return allItems.compactMap { item in
                guard let pid = item.runningApp?.processIdentifier, windowlessPIDs.contains(pid) else { return nil }
                var item = item
                item.dividerBefore = false
                return item
            }
        }
        guard let query else { return allItems }
        var shown: [DockItem] = []
        var divider = false
        for item in allItems {
            divider = divider || item.dividerBefore
            guard Search.rank(query, in: [item.name]) != nil else { continue }
            var item = item
            item.dividerBefore = divider && !shown.isEmpty
            divider = false
            shown.append(item)
        }
        return shown
    }

    /// True while there's a search (F), typing or read-only.
    var isSearching: Bool { query != nil }
    /// True while keys type into the search instead of running the Dock's commands.
    var isTyping: Bool { query != nil && typing }
    private var outsideClickMonitor: Any?
    /// The selected app's windows, previewed under its icon.
    private lazy var previews = WindowPreviews(panels: panels)

    /// True from Option+Tab until the Dock closes. Set synchronously so the event tap can route keys right away.
    private(set) var isOpen = false
    /// True while a tile's context menu is tracking; the event tap leaves the keyboard to the menu then.
    private(set) var menuOpen = false

    init() {
        panels.onHover = { [weak self] i in self?.select(i) }
        panels.onClick = { [weak self] i in
            self?.select(i)
            self?.activate()
        }
        panels.onRightClick = { [weak self] i, event in self?.showMenu(for: i, event: event) }
        panels.onPreviewHover = { [weak self] i in self?.previews.select(i) }
        panels.onPreviewClick = { [weak self] i in
            self?.previews.select(i)
            self?.activate()
        }
        panels.onPreviewRightClick = { [weak self] i, event in
            self?.previews.select(i)
            self?.showTilingMenu(at: event.screenLocation)
        }
        panels.onSearchClear = { [weak self] in self?.clearSearch() }
        // Only the window previews have the hover buttons; the Dock's own tiles are apps, folders and the Trash.
        panels.onPreviewWindowButton = { [weak self] i, button in
            guard let self else { return }
            self.previews.select(i)
            switch button {
            case .close: self.closePreviewWindow()
            case .minimize: self.toggleMinimizeSelected()
            case .fill: self.fillSelected()
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        // Build the list after the event tap callback returns.
        DispatchQueue.main.async { [self] in
            guard isOpen else { return }
            allItems = DockItems.current()
            guard !allItems.isEmpty else { return close() }
            smallestRowSide = min(36, DockItems.drawnIconSide() ?? 36)
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            selected = items.firstIndex { $0.runningApp?.processIdentifier == front } ?? 0
            // The first time the Dock ever appears, its help comes with it; the next few times, a tip in the bubble.
            let firstTime = !Settings.dockHelpShown
            if !firstTime, Settings.dockTipsShown < KeyHelp.dockTips.count {
                tip = KeyHelp.dockTips[Settings.dockTipsShown]
                Settings.dockTipsShown += 1
            }
            redraw()
            if firstTime {
                Settings.dockHelpShown = true
                panels.toggleHelp(title: KeyHelp.dockTitle, sections: KeyHelp.dock)
            }
            // After the icons have painted.
            DispatchQueue.main.async { self.updatePreviews() }
            // Clicks that land anywhere but our own windows close the Dock.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        previews.clear()
        panels.dismiss()
        allItems = []
        query = nil
        refused = ""
        tip = nil
        typing = false
        windowlessPIDs = nil
        itemBeforeWindowless = nil
        Thumbnails.shared.endSession()
    }

    /// Tab / Shift+Tab: the next or previous Dock item, leaving the previews.
    func move(_ delta: Int) {
        guard isOpen, !items.isEmpty else { return }
        select(wrapped(selected, by: delta, count: items.count))
    }

    /// Left / Right: between previews while in them, otherwise between Dock items.
    func moveHorizontal(_ delta: Int) {
        guard isOpen else { return }
        previews.selected == nil ? move(delta) : previews.move(delta)
    }

    /// Down: into the selected app's previews, or (in the grid layout) the row below.
    func moveDown() {
        guard isOpen, previews.selected == nil else { return }
        previews.isEmpty ? moveRow(1) : previews.select(0)
    }

    /// Up: from the previews back to the icons, or (in the grid layout) the row above.
    func moveUp() {
        guard isOpen else { return }
        if previews.selected != nil { return previews.select(nil) }
        moveRow(-1)
    }

    private func moveRow(_ delta: Int) {
        if let target = movedRows(selected, by: delta, columns: panels.columns, count: items.count) { select(target) }
    }

    /// Return or click: focus the highlighted preview's window, or else open the item like clicking it in the Dock.
    func activate() {
        guard isOpen else { return }
        if let window = previews.selectedWindow {
            close()
            return WindowManager.shared.focus(window)
        }
        guard items.indices.contains(selected) else { return }
        let item = items[selected]
        close()
        open(item)
    }

    /// W: close the highlighted preview's window, keeping the Dock up. Its preview goes at once, but if the window is
    /// still there a moment later (its app is asking something, such as whether to save), the preview comes back.
    func closePreviewWindow() {
        guard isOpen else { return }
        guard let window = previews.selectedWindow else {
            // Unlike M and T, W doesn't fall back to the app's most recent window: it closes only one you've picked.
            guard targetWindow != nil else { return showNotice(noWindowNotice()) }
            return showNotice(Settings.dockPreviews ? "Press ↓ to pick a window, then W"
                                                    : "Turn on Show Window Previews to close windows here")
        }
        switch WindowManager.shared.close(window) {
        case .noButton:
            showNotice(Notice.cantClose)
        case .pressed:
            previews.removeSelected(under: selected)
            confirmClosed(window)
        case .noAnswer:
            confirmClosed(window)
        }
    }

    /// A moment after W pressed `window`'s close button: if it's still there, its app is asking something (or wouldn't
    /// close it). The previews are read again, so it comes back, highlighted if its app is still selected, and a
    /// notice says so. If it's gone, so is its preview.
    private func confirmClosed(_ window: SwitcherWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isOpen else { return }
            let selectedApp = self.items.indices.contains(self.selected) ? self.items[self.selected].runningApp : nil
            let sameApp = selectedApp?.processIdentifier == window.app.processIdentifier
            guard WindowManager.shared.exists(window.id) else {
                // Closed after all, only slowly.
                if sameApp && self.previews.windows.contains(where: { $0.id == window.id }) { self.updatePreviews() }
                return
            }
            if sameApp {
                self.updatePreviews()
                if let i = self.previews.windows.firstIndex(where: { $0.id == window.id }) { self.previews.select(i) }
            }
            self.showNotice(Notice.notClosed(window.app))
        }
    }

    /// Says why a key did nothing, in place of a beep: a notice that fades away where the selected item's name goes.
    func showNotice(_ text: String) {
        guard isOpen else { return }
        panels.showNotice(text)
    }

    /// Why W, M or T has no window to act on: the selected item isn't an app with windows.
    private func noWindowNotice() -> String {
        guard items.indices.contains(selected) else { return "Nothing is selected" }
        let item = items[selected]
        switch item.kind {
        case .app(_, _, let running): return running == nil ? "\(item.name) isn't open" : "\(item.name) has no windows here"
        case .folder: return "“\(item.name)” is a folder"
        case .trash: return "The Trash has no windows"
        }
    }

    /// Why Q or H can't act on the selected item: it isn't a running app.
    private func notRunningNotice() -> String {
        guard items.indices.contains(selected) else { return "Nothing is selected" }
        let item = items[selected]
        if case .app = item.kind { return "\(item.name) isn't open" }
        return "Q and H work on open apps"
    }

    /// ?: shows or hides the list of keys and mouse actions.
    func toggleHelp() {
        guard isOpen else { return }
        panels.toggleHelp(title: KeyHelp.dockTitle, sections: KeyHelp.dock)
    }

    /// The window M and T act on: the highlighted preview's, or else the selected app's most recent one.
    private var targetWindow: SwitcherWindow? {
        if let window = previews.selectedWindow { return window }
        guard items.indices.contains(selected), let app = items[selected].runningApp else { return nil }
        return WindowManager.shared.currentWindows(of: app).first
    }

    /// M: minimize the window, or restore it, keeping the Dock up.
    func toggleMinimizeSelected() {
        guard isOpen else { return }
        guard let window = targetWindow else { return showNotice(noWindowNotice()) }
        guard WindowManager.shared.toggleMinimized(window) else { return showNotice(Notice.cantMinimize(restoring: window.isMinimized)) }
        // Re-read once the minimize animation is over (until then the window still counts as on screen).
        afterEach([0.5, 1.2]) { [weak self] in self?.updatePreviews() }
    }

    /// A preview's green button: fill the screen with the window (or put it back), close the Dock and bring the window
    /// forward, as the tiling menu's Fill does.
    private func fillSelected() {
        guard isOpen, let window = targetWindow else { return }
        WindowTiling.toggleFill(window)
        close()
        WindowManager.shared.focus(window)
    }

    /// Fn+number (Fn+1 … Fn+9, then Fn+0): open the item with that number, counting the items shown from the left, as
    /// Win+number does on the Windows taskbar. If there's no such item, a notice says so.
    func openItem(number: Int) {
        let i = (number + 9) % 10
        guard isOpen else { return }
        guard items.indices.contains(i) else { return showNotice("There's no item for Fn+\(number)") }
        let item = items[i]
        close()
        open(item)
    }

    /// While Fn is held, each of the first ten items shows its number (not while typing a search, where digits type).
    func setNumbersVisible(_ visible: Bool) {
        guard isOpen else { return }
        panels.setNumbersVisible(visible && !isTyping)
    }

    /// T: the tiling menu for the window, at its preview (or the app's icon).
    func showTilingMenuForSelected() {
        guard isOpen else { return }
        guard let window = targetWindow else { return showNotice(noWindowNotice()) }
        let frame = previews.selected.flatMap { panels.tileScreenFrame($0, preview: true) } ?? panels.tileScreenFrame(selected)
        guard let frame else { return }
        showTilingMenu(for: window, at: NSPoint(x: frame.minX, y: frame.minY))
    }

    /// N: a new window of the selected app, through its "New Window" menu item. An app that isn't running, or has no
    /// windows, opens as when clicked (launching it, or making a window); so do folders and the Trash. For an app with
    /// windows but no such item, a notice says so, and the Dock stays.
    func newWindowForSelected() {
        guard isOpen, items.indices.contains(selected) else { return }
        guard let app = items[selected].runningApp,
              !AX.elements(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute).isEmpty else {
            let item = items[selected]
            close()
            return open(item)
        }
        guard WindowManager.shared.newWindow(of: app) else { return showNotice(Notice.noNewWindow(app)) }
        close()
    }

    /// Q: quit the selected app, keeping the Dock up.
    func quitSelected() {
        guard isOpen, items.indices.contains(selected) else { return }
        guard let app = items[selected].runningApp else { return showNotice(notRunningNotice()) }
        guard WindowManager.shared.quit(app) else { return showNotice(Notice.cantQuit(app)) }
        // Among Z's apps it goes at once, and once none are left every item comes back.
        if windowlessPIDs != nil {
            windowlessPIDs?.remove(app.processIdentifier)
            if windowlessPIDs?.isEmpty ?? true {
                showAllItems()
            } else {
                selected = min(selected, items.count - 1)
                redraw()
            }
        }
        scheduleRefresh()
    }

    /// H: hide the selected app, or show it if it's hidden, keeping the Dock up.
    func toggleHideSelected() {
        guard isOpen, items.indices.contains(selected) else { return }
        guard let app = items[selected].runningApp else { return showNotice(notRunningNotice()) }
        WindowManager.shared.setHidden(app, !app.isHidden)
        scheduleRefresh()
    }

    /// R: items around a big ring, or the row again. Shared with the switcher and saved, so X keeps the ring. Unless
    /// it's turned on in the menu, a notice says where.
    func toggleRing() {
        guard isOpen, !items.isEmpty else { return }
        guard Settings.ringEnabled else { return showNotice(Notice.ringOff) }
        Settings.ringLayout.toggle()
        redraw()
        updatePreviews()
    }

    /// Z: only the running apps with no windows, to quit them with Q (or open one with Return), or every item again,
    /// with the one selected before still selected. A search goes first; if there are no such apps, a notice says so.
    func toggleWindowlessApps() {
        guard isOpen, !allItems.isEmpty else { return }
        if windowlessPIDs != nil { return showAllItems() }
        let withWindows = Set(WindowManager.shared.currentWindows().map(\.app.processIdentifier))
        let windowless = Set(WindowManager.shared.windowlessApps(listed: withWindows).map(\.processIdentifier))
        let pids = Set(allItems.compactMap { $0.runningApp?.processIdentifier }.filter(windowless.contains))
        guard !pids.isEmpty else { return showNotice(Notice.noWindowlessApps) }
        if query != nil { endSearch() }
        itemBeforeWindowless = items.indices.contains(selected) ? items[selected] : nil
        windowlessPIDs = pids
        selected = 0
        previews.clear()
        redraw()
    }

    private func showAllItems() {
        let target = itemBeforeWindowless
        windowlessPIDs = nil
        itemBeforeWindowless = nil
        selected = target.flatMap { t in items.firstIndex { Self.sameItem($0, t) } } ?? 0
        redraw()
        updatePreviews()
    }

    // MARK: - Search (F)

    /// F: type into the search, a new one (every item stays until something is typed) or the read-only one there.
    /// With Z on, every item comes back to be searched. False if it can't (nothing to search, or it's typing already).
    func beginSearch() -> Bool {
        guard isOpen, !allItems.isEmpty, !isTyping else { return false }
        if windowlessPIDs != nil { showAllItems() }
        if query == nil { query = "" }
        typing = true
        panels.setSearch(bubbleText)
        return true
    }

    /// A key typed into the search: adds `text` to it if anything still matches. If nothing does, it's refused: it
    /// shows in red after the search, and so do the keys after it, until they're deleted.
    func type(_ text: String) {
        guard isOpen, typing, let query else { return }
        if refused.isEmpty && search(query + text) { return }
        refused += text
        panels.setSearch(bubbleText)
    }

    /// Delete: the last refused key, or else the search's last character.
    func deleteBackward() {
        guard isOpen, typing, let query else { return }
        if !refused.isEmpty {
            refused.removeLast()
            return panels.setSearch(bubbleText)
        }
        guard !query.isEmpty else { return }
        search(String(query.dropLast()))
    }

    /// Cmd+Delete (Delete when read-only), or the search's clear button: the search empties, and every item is back,
    /// with the selection kept. The search stays.
    func clearSearch() {
        guard isOpen, let query, !query.isEmpty || !refused.isEmpty else { return }
        refused = ""
        search("")
    }

    /// Esc with a search: typing stops and what it found stays (read-only), so keys are the Dock's commands again;
    /// an empty search goes. False, doing nothing, for a read-only one with something in it (Esc then closes the Dock,
    /// as usual) or with no search.
    func escapeSearch() -> Bool {
        guard isOpen, let query else { return false }
        if query.isEmpty {
            endSearch()
        } else if typing {
            typing = false
            // Read-only, it's what was found that counts.
            refused = ""
            panels.setSearch(bubbleText)
        } else {
            return false
        }
        return true
    }

    /// The search goes, and every item is back, with the one found still selected.
    private func endSearch() {
        let current = items.indices.contains(selected) ? items[selected] : nil
        query = nil
        refused = ""
        typing = false
        selected = current.flatMap { cur in items.firstIndex { Self.sameItem($0, cur) } } ?? 0
        redraw()
        updatePreviews()
    }

    /// Shows the items matching `text` and selects the best match (for an empty search, the one already selected).
    /// False, changing nothing, if nothing matches.
    @discardableResult
    private func search(_ text: String) -> Bool {
        let current = items.indices.contains(selected) ? items[selected] : nil
        let ranked = allItems.compactMap { item in Search.rank(text, in: [item.name]).map { (item: item, rank: $0) } }
        // The first of the best, so ties go in Dock order.
        guard let best = ranked.min(by: { $0.rank < $1.rank })?.item else { return false }
        query = text
        let target = text.isEmpty ? current : best
        selected = target.flatMap { t in items.firstIndex { Self.sameItem($0, t) } } ?? 0
        redraw()
        schedulePreviews()
        return true
    }

    // MARK: - Drawing

    private func redraw() {
        let tiles = items.map { item -> SwitcherTile in
            var title = item.name
            if case .folder(let url) = item.kind { title = url.path }
            let app = item.runningApp
            return SwitcherTile(icon: item.icon, name: item.name, title: title, isMinimized: false,
                                isAppHidden: app?.isHidden ?? false, isRunning: app != nil)
        }
        let dividers = Set(items.indices.filter { items[$0].dividerBefore })
        // While searching, or with Z's apps, icons keep the size they have with the whole Dock shown.
        let whole = query == nil && windowlessPIDs == nil ? nil : (count: allItems.count, gaps: allItems.filter(\.dividerBefore).count)
        panels.show(tiles: tiles, selected: selected, thumbnails: false, dockStyle: true, dividers: dividers,
                    iconsLikeDock: whole, sizingCount: whole?.count, smallestRowSide: smallestRowSide)
        panels.setSearch(bubbleText)
    }

    /// What the bubble over the Dock shows: Z's label, the search, or a tip.
    private var bubbleText: PanelGroup.SearchText? {
        if windowlessPIDs != nil {
            return ("", "Apps with no windows", "Q to quit · Return to open · Z for every item", false, "app.dashed", "")
        }
        if let query {
            let found = "\(items.count) of \(allItems.count)"
            if !typing {
                return (query, "Search cleared", query.isEmpty ? "F to type · Esc to close" : "\(found) · F to edit · ⌫ to clear",
                        false, "magnifyingglass", "")
            }
            let hint = !refused.isEmpty ? "No match · ⌫ to delete" : query.isEmpty ? "Esc to close" : "\(found) · Return to open · Esc for keys"
            return (query, "Type to find an app or folder", hint, true, "magnifyingglass", refused)
        }
        return tip.map { ("", $0.title, $0.hint, false, "lightbulb", "") }
    }

    private func select(_ i: Int) {
        guard items.indices.contains(i) else { return }
        let changed = i != selected
        selected = i
        panels.setSelected(i)
        if changed { schedulePreviews() }
    }

    // MARK: - Window previews

    /// The selection moved: drop the old app's previews now, and show the new one's once the selection settles.
    private func schedulePreviews() {
        previews.schedule { [weak self] in self?.updatePreviews() }
    }

    /// Previews of the selected app's windows (per the Minimized / Hidden / All Desktops settings), with fresh snapshots.
    /// A highlighted preview stays highlighted (or, if its window dropped out, its neighbor does).
    private func updatePreviews() {
        guard isOpen else { return }
        let app = Settings.dockPreviews && windowlessPIDs == nil && items.indices.contains(selected) ? items[selected].runningApp : nil
        let windows = app.map { WindowManager.shared.currentWindows(of: $0) } ?? []
        let highlight = previews.selectedWindow.flatMap { kept in
            windows.firstIndex { $0.id == kept.id } ?? (windows.isEmpty ? nil : min(previews.selected!, windows.count - 1))
        }
        previews.show(windows, under: selected, selected: highlight, refreshThumbnails: true)
    }

    /// Quitting, launching and hiding take a moment; re-read the Dock once they've had time to land.
    private func scheduleRefresh() {
        afterEach([0.4, 1.2]) { [weak self] in self?.refresh() }
    }

    private func refresh() {
        guard isOpen, !menuOpen else { return }
        let current = items.indices.contains(selected) ? items[selected] : nil
        allItems = DockItems.current()
        guard !allItems.isEmpty else { return close() }
        // None of Z's apps are left (they quit or opened a window): every item is back.
        if windowlessPIDs != nil && items.isEmpty {
            windowlessPIDs = nil
            itemBeforeWindowless = nil
        }
        // Nothing left that the search found (the only match quit): it goes, and every item is back.
        if query != nil && items.isEmpty {
            query = nil
            refused = ""
            typing = false
        }
        // Keep the selection on the same item if it's still there (an unpinned app that quit drops out).
        selected = current.flatMap { cur in items.firstIndex { Self.sameItem($0, cur) } } ?? min(selected, items.count - 1)
        redraw()
        updatePreviews()
    }

    private static func sameItem(_ a: DockItem, _ b: DockItem) -> Bool {
        switch (a.kind, b.kind) {
        case let (.app(u1, _, _), .app(u2, _, _)), let (.folder(u1), .folder(u2)): return u1 == u2
        case (.trash, .trash): return true
        default: return false
        }
    }

    // MARK: - Actions

    private func open(_ item: DockItem) {
        switch item.kind {
        case .app(let url, _, let running):
            if let running, running.isHidden { running.unhide() }
            // For a running app this activates it and sends it a reopen event, just like a Dock click, so an app with
            // no windows opens a new one.
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        case .folder(let url):
            NSWorkspace.shared.open(url)
        case .trash:
            NSWorkspace.shared.open(DockItems.trashURL)
        }
    }

    private func showInFinder(_ url: URL) {
        close()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func emptyTrash() {
        close()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to permanently erase the items in the Trash?"
        alert.informativeText = "You can't undo this action."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
        if let error { NSLog("CmdTab: Empty Trash failed: \(error)") }
    }

    // MARK: - Context menu

    private func showMenu(for index: Int, event: NSEvent) {
        guard isOpen, items.indices.contains(index) else { return }
        select(index)
        let item = items[index]
        let menu = NSMenu()
        menu.autoenablesItems = false

        switch item.kind {
        case .app(let url, _, let running):
            if let running {
                let windows = WindowManager.shared.currentWindows(of: running)
                for w in windows {
                    // The Dock marks minimized windows with a diamond.
                    menu.addItem(ActionItem(w.isMinimized ? "◆ \(w.title)" : w.title) { [weak self] in
                        self?.close()
                        WindowManager.shared.focus(w)
                    })
                }
                if !windows.isEmpty { menu.addItem(.separator()) }
                menu.addItem(ActionItem("Show in Finder") { [weak self] in self?.showInFinder(url) })
                menu.addItem(.separator())
                menu.addItem(ActionItem(running.isHidden ? "Show" : "Hide") { [weak self] in
                    WindowManager.shared.setHidden(running, !running.isHidden)
                    self?.scheduleRefresh()
                })
                // Finder can't be quit, so, as in the Dock, it has no Quit.
                if running.bundleIdentifier != "com.apple.finder" {
                    let quit = ActionItem("Quit") { [weak self] in
                        if WindowManager.shared.quit(running) { self?.scheduleRefresh() } else { self?.showNotice(Notice.cantQuit(running)) }
                    }
                    // Holding Option turns Quit into Force Quit, like the Dock.
                    let forceQuit = ActionItem("Force Quit") { [weak self] in
                        running.forceTerminate()
                        self?.scheduleRefresh()
                    }
                    forceQuit.isAlternate = true
                    forceQuit.keyEquivalentModifierMask = .option
                    menu.addItem(quit)
                    menu.addItem(forceQuit)
                }
            } else {
                menu.addItem(ActionItem("Open") { [weak self] in self?.activate() })
                menu.addItem(ActionItem("Show in Finder") { [weak self] in self?.showInFinder(url) })
            }
        case .folder(let url):
            menu.addItem(ActionItem("Open") { [weak self] in self?.activate() })
            menu.addItem(ActionItem("Show in Finder") { [weak self] in self?.showInFinder(url) })
        case .trash:
            menu.addItem(ActionItem("Open") { [weak self] in self?.activate() })
            menu.addItem(.separator())
            menu.addItem(ActionItem("Empty Trash…") { [weak self] in self?.emptyTrash() })
        }

        popUp(menu, at: event.screenLocation)
    }

    /// Right-click on a window preview: the green button's layouts (Fill, halves, ...) for that window.
    private func showTilingMenu(at point: NSPoint) {
        guard isOpen, let window = previews.selectedWindow else { return }
        showTilingMenu(for: window, at: point)
    }

    /// The tiling menu for `window`, at `point` (screen coordinates). Choosing a layout applies it, closes the Dock and
    /// brings the window forward; dismissing the menu leaves the Dock up.
    private func showTilingMenu(for window: SwitcherWindow, at point: NSPoint) {
        // Arrangements (side by side, ...) also place the next most recent windows, of any app.
        let menu = WindowTiling.menu(for: window, others: WindowManager.shared.currentWindows()) { [weak self] in
            self?.close()
            WindowManager.shared.focus(window)
        }
        popUp(menu, at: point)
    }

    /// popUp tracks the menu modally and returns once it closes; the chosen item's action runs before that.
    private func popUp(_ menu: NSMenu, at point: NSPoint) {
        menuOpen = true
        menu.popUp(positioning: nil, at: point, in: nil)
        menuOpen = false
    }
}
