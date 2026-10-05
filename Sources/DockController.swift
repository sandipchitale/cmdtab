import AppKit

/// The Option+Tab Dock: a Dock-like row of apps, folders and the Trash that stays up until you pick something, press
/// Esc or Option+Tab, or click outside it.
@MainActor
final class DockController {
    private let panels = PanelGroup()
    private var items: [DockItem] = []
    private var selected = 0
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
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        // Build the list after the event tap callback returns.
        DispatchQueue.main.async { [self] in
            guard isOpen else { return }
            items = DockItems.current()
            guard !items.isEmpty else { return close() }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            selected = items.firstIndex { $0.runningApp?.processIdentifier == front } ?? 0
            redraw()
            // The first time the Dock ever appears, its help comes with it.
            if !Settings.dockHelpShown {
                Settings.dockHelpShown = true
                panels.toggleHelp(title: KeyHelp.dockTitle, rows: KeyHelp.dock)
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
        items = []
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

    /// W: close the highlighted preview's window, keeping the Dock up.
    func closePreviewWindow() {
        guard isOpen, let window = previews.selectedWindow else { return NSSound.beep() }
        guard WindowManager.shared.close(window) else { return NSSound.beep() }
        previews.removeSelected(under: selected)
    }

    /// ?: shows or hides the list of keys and mouse actions.
    func toggleHelp() {
        guard isOpen else { return }
        panels.toggleHelp(title: KeyHelp.dockTitle, rows: KeyHelp.dock)
    }

    /// The window M and T act on: the highlighted preview's, or else the selected app's most recent one.
    private var targetWindow: SwitcherWindow? {
        if let window = previews.selectedWindow { return window }
        guard items.indices.contains(selected), let app = items[selected].runningApp else { return nil }
        return WindowManager.shared.currentWindows(of: app).first
    }

    /// M: minimize the window, or restore it, keeping the Dock up.
    func toggleMinimizeSelected() {
        guard isOpen, let window = targetWindow, WindowManager.shared.toggleMinimized(window) else { return NSSound.beep() }
        // Re-read once the minimize animation is over (until then the window still counts as on screen).
        afterEach([0.5, 1.2]) { [weak self] in self?.updatePreviews() }
    }

    /// T: the tiling menu for the window, at its preview (or the app's icon).
    func showTilingMenuForSelected() {
        guard isOpen, let window = targetWindow else { return NSSound.beep() }
        let frame = previews.selected.flatMap { panels.tileScreenFrame($0, preview: true) } ?? panels.tileScreenFrame(selected)
        guard let frame else { return NSSound.beep() }
        showTilingMenu(for: window, at: NSPoint(x: frame.minX, y: frame.minY))
    }

    /// N: a new window of the selected app, through its "New Window" menu item. An app that isn't running, or has no
    /// windows, opens as when clicked (launching it, or making a window); so do folders and the Trash. An app with
    /// windows but no such item beeps, and the Dock stays.
    func newWindowForSelected() {
        guard isOpen, items.indices.contains(selected) else { return }
        guard let app = items[selected].runningApp,
              !AX.elements(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute).isEmpty else {
            let item = items[selected]
            close()
            return open(item)
        }
        guard WindowManager.shared.newWindow(of: app) else { return NSSound.beep() }
        close()
    }

    /// Q: quit the selected app, keeping the Dock up.
    func quitSelected() {
        guard isOpen, items.indices.contains(selected), let app = items[selected].runningApp else { return NSSound.beep() }
        if WindowManager.shared.quit(app) { scheduleRefresh() } else { NSSound.beep() }
    }

    /// H: hide the selected app, or show it if it's hidden, keeping the Dock up.
    func toggleHideSelected() {
        guard isOpen, items.indices.contains(selected), let app = items[selected].runningApp else { return NSSound.beep() }
        WindowManager.shared.setHidden(app, !app.isHidden)
        scheduleRefresh()
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
        panels.show(tiles: tiles, selected: selected, thumbnails: false, dockStyle: true, dividers: dividers)
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
        let app = Settings.dockPreviews && items.indices.contains(selected) ? items[selected].runningApp : nil
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
        items = DockItems.current()
        guard !items.isEmpty else { return close() }
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
                let quit = ActionItem("Quit") { [weak self] in
                    if WindowManager.shared.quit(running) { self?.scheduleRefresh() } else { NSSound.beep() }
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
