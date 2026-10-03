import AppKit

/// One tile in the grid: a window (Cmd+Tab) or a Dock item (Option+Tab).
struct SwitcherTile {
    let icon: NSImage
    /// Shown in the bubble above the selected icon in icon view.
    let name: String
    /// The hover tooltip in icon view, and the header in thumbnail view.
    let title: String
    var isMinimized = false
    var isAppHidden = false
    /// Draws the Dock's running-app dot under the icon.
    var isRunning = false
    /// The window to show a snapshot of in thumbnail view.
    var windowID: CGWindowID?
}

extension SwitcherTile {
    /// Named after the app, or after the window itself with `nameByTitle` (when the app's icon appears more than once).
    init(window w: SwitcherWindow, nameByTitle: Bool = false) {
        self.init(icon: w.app.icon ?? NSImage(), name: nameByTitle ? w.title : w.app.localizedName ?? w.title, title: w.title,
                  isMinimized: w.isMinimized, isAppHidden: w.isAppHidden, windowID: w.id)
    }
}
