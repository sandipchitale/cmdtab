import AppKit

/// State machine for one Cmd+Tab session: begin -> move* -> commit | cancel.
@MainActor
final class SwitcherController {
    private let panels = PanelGroup()
    private var windows: [SwitcherWindow] = []
    private var selected = 0
    private var pendingShow: DispatchWorkItem?
    private var running = false

    /// Called when a switch finishes by some route other than releasing Cmd (mouse click).
    var onFinished: (() -> Void)?

    /// A quick Cmd+Tab tap shorter than this switches without ever flashing the UI (like Windows).
    private let showDelay: TimeInterval = 0.12

    init() {
        panels.onHover = { [weak self] i in self?.select(i) }
        panels.onClick = { [weak self] i in
            guard let self else { return }
            self.select(i)
            self.commit()
            self.onFinished?()
        }
        // Clicking the preview switches to its window, which is the selected one.
        panels.onPreviewClick = { [weak self] _ in
            self?.commit()
            self?.onFinished?()
        }
    }

    /// In icon view, a preview of the selected window can hang below its icon, like the Dock's window previews.
    private var showsPreview: Bool { !Settings.showThumbnails && Settings.switcherPreviews }

    private func updatePreview() {
        guard showsPreview, panels.isVisible, windows.indices.contains(selected) else { return panels.hidePreviews() }
        panels.showPreviews(tiles: [SwitcherTile(window: windows[selected])], under: selected, selected: nil)
    }

    private func showPanels() {
        // An app's name doesn't tell its windows apart, so apps with several windows listed show the window title.
        var windowCounts: [pid_t: Int] = [:]
        for w in windows { windowCounts[w.app.processIdentifier, default: 0] += 1 }
        let tiles = windows.map { SwitcherTile(window: $0, nameByTitle: windowCounts[$0.app.processIdentifier, default: 0] > 1) }
        // App icons are the same size as in the Option+Tab Dock.
        let thumbnails = Settings.showThumbnails
        let dock = thumbnails ? [] : DockItems.current()
        panels.show(tiles: tiles, selected: selected, thumbnails: thumbnails,
                    iconsLikeDock: thumbnails ? nil : (dock.count, dock.filter(\.dividerBefore).count))
        updatePreview()
    }

    func begin(backwards: Bool) {
        running = true
        windows = WindowManager.shared.currentWindows()
        guard !windows.isEmpty else { return }
        selected = backwards ? windows.count - 1 : min(1, windows.count - 1)
        if Settings.showThumbnails || showsPreview {
            Thumbnails.shared.retain(only: windows.map(\.id))
            Thumbnails.shared.refresh(windows.map(\.id)) { [weak self] id, image in
                guard let self, self.running else { return }
                self.panels.setThumbnail(image, for: id)
                self.panels.setPreviewThumbnail(image, for: id)
            }
        }

        let work = DispatchWorkItem { [weak self] in self?.showNow() }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    func move(_ delta: Int) {
        guard running, !windows.isEmpty else { return }
        select(wrapped(selected, by: delta, count: windows.count))
        showNow()
    }

    func moveRow(_ delta: Int) {
        guard running, !windows.isEmpty else { return }
        let target = selected + delta * panels.columns
        if windows.indices.contains(target) { select(target) }
        showNow()
    }

    func commit() {
        guard running else { return }
        let target = windows.indices.contains(selected) ? windows[selected] : nil
        reset()
        if let target { WindowManager.shared.focus(target) }
    }

    func cancel() {
        reset()
    }

    /// Cmd+W: close the selected window and keep the switcher open.
    func closeSelected() {
        guard running, windows.indices.contains(selected) else { return }
        let target = windows[selected]
        if WindowManager.shared.close(target) {
            remove { $0.id == target.id }
        } else {
            NSSound.beep()
        }
    }

    /// Cmd+Q: quit the selected window's app and keep the switcher open.
    func quitSelected() {
        guard running, windows.indices.contains(selected) else { return }
        let app = windows[selected].app
        if WindowManager.shared.quit(app) {
            remove { $0.app.processIdentifier == app.processIdentifier }
        } else {
            NSSound.beep()
        }
    }

    /// Cmd+M: minimize the selected window, or restore it if it's already minimized.
    func toggleMinimizeSelected() {
        guard running, windows.indices.contains(selected) else { return }
        let target = windows[selected]
        guard WindowManager.shared.setMinimized(target, !target.isMinimized) else { return NSSound.beep() }
        windows[selected].isMinimized.toggle()
        // Restoring a window of a hidden app also unhides the app (like clicking its Dock thumbnail), so the
        // window and the badges end up in a clear state. macOS alone may show the window yet keep the app "hidden".
        if target.isMinimized && target.isAppHidden {
            let pid = target.app.processIdentifier
            WindowManager.shared.setHidden(target.app, false)
            for i in windows.indices where windows[i].app.processIdentifier == pid { windows[i].isAppHidden = false }
        }
        scheduleSync()
        if windows[selected].isMinimized && !Settings.includeMinimized {
            remove { $0.id == target.id }
        } else {
            redraw()
        }
    }

    /// Cmd+H: hide the selected window's app, or unhide it if it's already hidden.
    func toggleHideSelected() {
        guard running, windows.indices.contains(selected) else { return }
        let target = windows[selected]
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

    /// The toggles update tiles optimistically, but macOS may do more (some apps unhide when a window is
    /// un-minimized) and hide/unhide apply asynchronously. Re-read the real state once things settle.
    private func scheduleSync() {
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.syncStates() }
        }
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
        selected = min(selected, windows.count - 1)
        redraw()
    }

    /// Re-lays out the grid after windows were removed or changed state, keeping the order and selection.
    private func redraw() {
        showPanels()
        pendingShow?.cancel()
        pendingShow = nil
    }

    private func select(_ i: Int) {
        guard windows.indices.contains(i) else { return }
        selected = i
        panels.setSelected(i)
        if panels.isVisible { updatePreview() }
    }

    private func showNow() {
        pendingShow?.cancel()
        pendingShow = nil
        guard running, !windows.isEmpty, !panels.isVisible else { return }
        showPanels()
    }

    private func reset() {
        running = false
        pendingShow?.cancel()
        pendingShow = nil
        panels.dismiss()
        windows = []
    }
}
