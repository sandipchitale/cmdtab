import AppKit

/// The keys and mouse actions of the switcher and the Dock, as their ? help and the Keyboard Shortcuts window show
/// them. Both lists run in the same order: navigation, acting on the selection, modes, then help, closing and the mouse.
enum KeyHelp {
    static let switcherTitle = "Cmd+Tab — let go of ⌘, or press Return, to switch"
    static let switcher: [(String, String)] = [
        ("Tab  ⇧Tab", "Next / previous window"),
        ("← → ↑ ↓", "Move around the grid"),
        ("↓  ↑", "Grouped: into the app's windows / back"),
        ("Release ⌘, Return", "Switch to the selected window"),
        ("W", "Close the window"),
        ("Q", "Quit its app"),
        ("M", "Minimize / restore the window"),
        ("H", "Hide / show its app"),
        ("N", "New window of its app"),
        ("T", "Tile the window: Fill, halves, quarters, ..."),
        ("G", "Group / ungroup by app"),
        ("X", "Exchange: switch to the Dock"),
        ("?", "Show / hide this help"),
        ("Esc", "Cancel"),
        ("Hover, click", "Select, switch"),
        ("Right-click", "Tile the window: Fill, halves, quarters, ..."),
    ]

    static let dockTitle = "Option+Tab Dock — stays up until you choose"
    static let dock: [(String, String)] = [
        ("Tab  ⇧Tab", "Next / previous item"),
        ("← →", "Next / previous item, or window in the previews"),
        ("↓  ↑", "Into the app's window previews / back"),
        ("Return", "Open the item, or the highlighted window"),
        ("W", "Close the highlighted window"),
        ("Q", "Quit the app"),
        ("M", "Minimize / restore the window"),
        ("H", "Hide / show the app"),
        ("N", "New window of the app (or open it)"),
        ("T", "Tile the window: Fill, halves, quarters, ..."),
        ("X", "Exchange: switch to the window switcher"),
        ("?", "Show / hide this help"),
        ("Esc, ⌥Tab", "Close"),
        ("Hover, click", "Select, open"),
        ("Right-click", "Windows, Show in Finder, Hide, Quit, ..."),
        ("Right-click a preview", "Tile the window: Fill, halves, quarters, ..."),
        ("Click outside", "Close"),
    ]
    /// What "the window" is in the Dock (M and T).
    static let dockWindowNote = "The window: the highlighted preview's, or else the app's most recent one."
}

/// Both lists side by side in a regular window, from the menu bar menu (Keyboard Shortcuts…).
@MainActor
final class ShortcutsWindow: NSObject, NSWindowDelegate {
    static let shared = ShortcutsWindow()
    /// The app that had the focus before the window came up, which gets it back when it closes.
    private var previousApp: NSRunningApplication?

    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "CmdTab Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let dock = NSMutableAttributedString(attributedString: HelpBubble.text(title: KeyHelp.dockTitle, rows: KeyHelp.dock))
        dock.append(NSAttributedString(string: "\n\n" + KeyHelp.dockWindowNote, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        let stack = NSStackView(views: [Self.column(HelpBubble.text(title: KeyHelp.switcherTitle, rows: KeyHelp.switcher)),
                                        Self.column(dock)])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 32
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        return window
    }()

    private static func column(_ text: NSAttributedString) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: text)
        label.maximumNumberOfLines = 0
        return label
    }

    func show() {
        if !window.isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front == .current ? nil : front
            window.center()
        }
        // CmdTab runs without a Dock icon, so macOS may not make it the active app: activate it, then bring the window
        // forward regardless.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// CmdTab has no other windows: hand the focus back to the app that had it.
    func windowWillClose(_ notification: Notification) {
        previousApp?.activate()
        previousApp = nil
    }
}
