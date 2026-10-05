import AppKit

/// The keys and mouse actions of the switcher and the Dock, as their ? help and the Keyboard Shortcuts window show
/// them. Both lists have the same sections, in the same order: moving and choosing, acting on the selection, finding
/// and views, the switcher or the Dock itself, then the mouse. Keys for what's turned off (R, and in the Dock the window
/// previews) aren't listed. Also the tips, and the welcome.
enum KeyHelp {
    /// Rows of keys, and what they do.
    typealias Section = [(String, String)]

    static let switcherTitle = "Cmd+Tab — let go of ⌘, or press Return, to switch"
    static var switcher: [Section] {
        let move: Section = [
            ("Tab  ⇧Tab", "Next / previous window"),
            ("← → ↑ ↓", "Move around the grid"),
            ("↓  ↑", "Grouped: into the app's windows / back"),
            ("Release ⌘, Return", "Switch to the selected window"),
        ]
        let act: Section = [
            ("W", "Close the window"),
            ("Q", "Quit its app"),
            ("M", "Minimize / restore the window"),
            ("H", "Hide / show its app"),
            ("N", "New window of its app"),
            ("T", "Tile the window: Fill, halves, quarters, …"),
        ]
        var find: Section = [
            ("F", "Find: type part of a name or title"),
            ("Esc  F", "Finding: stop typing, keeping the matches / type again"),
            ("G", "Group / ungroup by app"),
            (".", "App icons / window thumbnails"),
            ("Z", "Apps with no windows, to quit (Q) or open / back"),
        ]
        if Settings.ringEnabled { find.append(("R", "Ring / grid (the Dock too)")) }
        let itself: Section = [
            ("K", "Keep open after letting go of ⌘ / back (⌃⌥Tab opens it so)"),
            ("X", "Exchange: switch to the Dock"),
            ("?", "Show / hide this help"),
            ("Esc", "Cancel"),
        ]
        let mouse: Section = [
            ("Hover, click", "Select, switch"),
            ("Hover a tile", "Red closes, yellow minimizes, green fills / restores"),
            ("Right-click", "Tile the window: Fill, halves, quarters, …"),
        ]
        return [move, act, find, itself, mouse]
    }

    static let dockTitle = "Option+Tab Dock — stays up until you choose"
    static var dock: [Section] {
        // Without window previews, there's no window to highlight.
        let previews = Settings.dockPreviews
        var move: Section = [
            ("Tab  ⇧Tab", "Next / previous item"),
            ("← →", previews ? "Next / previous item, or window in the previews" : "Next / previous item"),
        ]
        if previews { move.append(("↓  ↑", "Into the app's window previews / back")) }
        move.append(("Return", previews ? "Open the item, or the highlighted window" : "Open the item"))
        move.append(("Fn 1 … 9, 0", "Open the 1st … 10th item (Fn shows the numbers)"))
        var act: Section = previews ? [("W", "Close the highlighted window")] : []
        act += [
            ("Q", "Quit the app"),
            ("M", "Minimize / restore the window"),
            ("H", "Hide / show the app"),
            ("N", "New window of the app (or open it)"),
            ("T", "Tile the window: Fill, halves, quarters, …"),
        ]
        var find: Section = [
            ("F", "Find: type part of a name"),
            ("Esc  F", "Finding: stop typing, keeping the matches / type again"),
            ("Z", "Apps with no windows, to quit (Q) or open / back"),
        ]
        if Settings.ringEnabled { find.append(("R", "Ring / row (the switcher too)")) }
        let itself: Section = [
            ("X", "Exchange: switch to the window switcher"),
            ("?", "Show / hide this help"),
            ("Esc, ⌥Tab", "Close"),
        ]
        var mouse: Section = [("Hover, click", "Select, open")]
        if previews { mouse.append(("Hover a preview", "Red closes, yellow minimizes, green fills / restores")) }
        mouse.append(("Right-click", "Windows, Show in Finder, Hide, Quit, …"))
        if previews { mouse.append(("Right-click a preview", "Tile the window: Fill, halves, quarters, …")) }
        mouse.append(("Click outside", "Close"))
        return [move, act, find, itself, mouse]
    }

    /// What "the window" is in the Dock (M and T).
    static let dockWindowNote = "The window: the highlighted preview's, or else the app's most recent one."

    /// One at a time, the first few times the switcher appears after its help: a key worth knowing, in the bubble over
    /// it.
    static let switcherTips: [(title: String, hint: String)] = [
        ("W closes the selected window", "and the switcher stays up for the next"),
        ("F finds a window", "type part of its name or title"),
        ("G groups the windows by app", "like the usual Cmd+Tab"),
        ("Option+Tab brings up a Dock anywhere", "X switches to it from here"),
        ("M minimizes the window, H hides its app", "press again to bring it back"),
        ("K keeps the switcher open", "after you let go of ⌘"),
        ("Z shows the apps that have no windows", "Q quits them"),
        ("Right-click a window, or press T", "to tile it"),
        ("? shows all the keys", ""),
    ]
    /// Likewise for the Dock.
    static let dockTips: [(title: String, hint: String)] = [
        ("F finds an app, a folder or the Trash", "type part of its name"),
        ("Hold Fn to see the numbers", "Fn+number opens that item"),
        ("Right-click an app", "for its windows, Hide and Quit"),
        ("Q quits the selected app", "and the Dock stays up for the next"),
        ("Z shows the apps that have no windows", "Q quits them"),
        ("X switches to the window switcher", "as Cmd+Tab would"),
        ("? shows all the keys", ""),
    ]

    /// What the welcome says over the lists, the first time CmdTab runs: what it changes, and where to find out more.
    static var welcome: NSAttributedString {
        let text = NSMutableAttributedString(string: "CmdTab is on. Here's what it changes:", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.labelColor,
        ])
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 5
        // Lines that wrap line up after the bullet.
        style.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
        style.headIndent = 14
        for line in [
            "Cmd+Tab switches between windows. Tap it to go back to the last one, or hold ⌘ and press Tab to choose.",
            "Option+Tab brings up a Dock wherever you are.",
            "A window's green button, or a double-click on its title bar, fills the screen. Option-click it for full screen.",
            "In the switcher or the Dock, press ? to see its keys. They're all below, too.",
            "The menu bar icon has the settings, and can turn any of this off.",
        ] {
            text.append(NSAttributedString(string: "\n•\t" + line, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
            ]))
        }
        return text
    }
}

/// What the switcher and the Dock say, in a notice that fades away, when a key can't do anything (instead of beeping).
enum Notice {
    static let ringOff = "R needs “R Toggles Ring Layout” in the CmdTab menu"
    static let noWindowlessApps = "No apps are running without windows"
    static let cantClose = "This window can't be closed"
    /// W, M or T among Z's apps.
    static let noWindowsAmongApps = "These apps have no windows"
    /// G or . among Z's apps.
    static let groupAmongApps = "These apps are one icon each already · Z for the windows"
    static let viewAmongApps = "Apps with no windows have no thumbnails · Z for the windows"

    static func cantMinimize(restoring: Bool) -> String {
        restoring ? "This window can't be restored" : "This window can't be minimized"
    }

    static func cantQuit(_ app: NSRunningApplication) -> String {
        app.bundleIdentifier == "com.apple.finder" ? "Finder can't be quit" : "\(name(of: app)) can't be quit"
    }

    static func noNewWindow(_ app: NSRunningApplication) -> String { "\(name(of: app)) has no New Window command" }

    /// A window W asked to close is still there a moment later.
    static func notClosed(_ app: NSRunningApplication) -> String {
        "\(name(of: app)) didn't close the window. It may be asking you something."
    }

    private static func name(of app: NSRunningApplication) -> String { app.localizedName ?? "The app" }
}

/// Both lists side by side in a regular window, from the menu bar menu (Keyboard Shortcuts…). The first time CmdTab
/// runs, it comes up by itself, with a welcome over the lists.
@MainActor
final class ShortcutsWindow: NSObject, NSWindowDelegate {
    static let shared = ShortcutsWindow()
    /// The app that had the focus before the window came up, which gets it back when it closes.
    private var previousApp: NSRunningApplication?

    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }()

    /// Both lists side by side, under the `welcome` if asked, in a view of the size they need. Built each time the
    /// window opens, since what's listed follows the settings. Laid out from the texts' own sizes: a label's fitting
    /// size comes out short of text with paragraph spacing, which cut off the margins.
    private static func content(welcome: Bool) -> NSView {
        let switcher = HelpBubble.text(title: KeyHelp.switcherTitle, sections: KeyHelp.switcher)
        let dock = NSMutableAttributedString(attributedString: HelpBubble.text(title: KeyHelp.dockTitle, sections: KeyHelp.dock))
        dock.append(NSAttributedString(string: "\n\n" + KeyHelp.dockWindowNote, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        let intro = welcome ? KeyHelp.welcome : nil
        let margin = NSSize(width: 24, height: 20), columnGap: CGFloat = 32, introGap: CGFloat = 22
        let left = size(of: switcher), right = size(of: dock), introSize = intro.map(size(of:)) ?? .zero
        let listsTop = margin.height + (intro == nil ? 0 : introSize.height + introGap)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: max(left.width + columnGap + right.width, introSize.width) + margin.width * 2,
                                        height: listsTop + max(left.height, right.height) + margin.height))
        /// `text` at `x`, `top` points below the view's top.
        func place(_ text: NSAttributedString, size: NSSize, x: CGFloat, top: CGFloat) {
            let label = NSTextField(labelWithAttributedString: text)
            label.maximumNumberOfLines = 0
            label.frame = NSRect(x: x, y: view.frame.height - top - size.height, width: size.width, height: size.height)
            view.addSubview(label)
        }
        if let intro { place(intro, size: introSize, x: margin.width, top: margin.height) }
        place(switcher, size: left, x: margin.width, top: listsTop)
        place(dock, size: right, x: margin.width + left.width + columnGap, top: listsTop)
        return view
    }

    /// The room a label needs for `text`: the text's own size, and a little for the label's padding.
    private static func size(of text: NSAttributedString) -> NSSize {
        let bounds = text.boundingRect(with: NSSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(bounds.width) + 6, height: ceil(bounds.height) + 4)
    }

    /// Brings the window up: the lists, or with `welcome`, a welcome over them.
    func show(welcome: Bool = false) {
        if !window.isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front == .current ? nil : front
            window.title = welcome ? "Welcome to CmdTab" : "CmdTab Keyboard Shortcuts"
            let content = Self.content(welcome: welcome)
            let size = content.frame.size
            window.contentView = content
            window.setContentSize(size)
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
