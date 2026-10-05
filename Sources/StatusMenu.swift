import AppKit
import ServiceManagement

/// The menu bar icon and its menu of settings.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    /// Called after "Cmd+Tab Shows Windows" is toggled.
    private let onSwitcherToggled: () -> Void
    /// Called after "Option+Tab Shows Dock" is turned off.
    private let onDockTurnedOff: () -> Void

    /// "CmdTab 0.0.1", from the app bundle's version.
    private static let title: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "CmdTab \($0)" } ?? "CmdTab"
    }()

    init(onSwitcherToggled: @escaping () -> Void, onDockTurnedOff: @escaping () -> Void) {
        self.onSwitcherToggled = onSwitcherToggled
        self.onDockTurnedOff = onDockTurnedOff
        super.init()
        let image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "CmdTab")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "\(Self.title) — Windows-style Cmd+Tab"
        menu.delegate = self
        build()
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { menu.updateActionItems() }

    private func build() {
        let header = NSMenuItem(title: "\(Self.title) — Windows-style window switcher", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Cmd+Tab, with its options indented under it (and disabled while it's off).
        menu.addItem(ActionItem("Cmd+Tab Shows Windows", isOn: { Settings.enabled }) { [weak self] in
            Settings.enabled.toggle()
            self?.onSwitcherToggled()
        })
        let switcherOptions = [
            ActionItem("Include Minimized Windows", indent: 3, isOn: { Settings.includeMinimized }) {
                Settings.includeMinimized.toggle()
            },
            ActionItem("Include Windows of Hidden Apps", indent: 3, isOn: { Settings.includeHiddenApps }) {
                Settings.includeHiddenApps.toggle()
            },
            ActionItem("Include Windows from All Desktops", indent: 3, isOn: { Settings.includeAllSpaces }) {
                Settings.includeAllSpaces.toggle()
            },
            ActionItem("Show App Icons", indent: 3, isOn: { !Settings.showThumbnails }) {
                Settings.showThumbnails = false
            },
            previewItem(),
            thumbnailsItem(),
        ]
        for item in switcherOptions {
            if item.isEnabledWhen == nil { item.isEnabledWhen = { Settings.enabled } }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // Option+Tab, with its option.
        menu.addItem(ActionItem("Option+Tab Shows Dock", isOn: { Settings.dockEnabled }) { [weak self] in
            Settings.dockEnabled.toggle()
            if !Settings.dockEnabled { self?.onDockTurnedOff() }
        })
        let dockPreviews = ActionItem("Show Window Previews", indent: 3, isOn: { Settings.dockPreviews }) {
            Settings.dockPreviews.toggle()
        }
        dockPreviews.isEnabledWhen = { Settings.dockEnabled }
        menu.addItem(dockPreviews)
        menu.addItem(.separator())

        // Where the switcher and the Dock appear, and how they look.
        menu.addItem(choiceMenu("Show On", choices: [("All Displays", "all"), ("Display with Pointer", "pointer"),
                                                     ("Display with Active Window", "activeWindow")],
                                current: { Settings.showOnAllDisplays ? "all" : Settings.switcherDisplay }) { value in
            Settings.showOnAllDisplays = value == "all"
            if value != "all" { Settings.switcherDisplay = value }
        })
        menu.addItem(choiceMenu("Appearance", choices: [("System", "system"), ("Light", "light"), ("Dark", "dark")],
                                current: { Settings.appearance }) { Settings.appearance = $0 })
        menu.addItem(.separator())

        menu.addItem(ActionItem("Green Button Toggles Maximize Instead of Full Screen", isOn: { Settings.greenButtonZooms }) {
            Settings.greenButtonZooms.toggle()
        })
        menu.addItem(.separator())

        menu.addItem(ActionItem("Keyboard Shortcuts…") { ShortcutsWindow.shared.show() })
        menu.addItem(launchAtLoginItem())
        menu.addItem(accessibilityItem())
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit CmdTab", keyEquivalent: "q") {
            NativeSwitcher.setEnabled(true)
            NSApp.terminate(nil)
        })
        menu.updateActionItems()
    }

    /// The icon view's window preview: needs Screen Recording, so turning it on asks for that.
    private func previewItem() -> ActionItem {
        let item = ActionItem("Show Window Preview", indent: 6, isOn: { Settings.switcherPreviews }) {
            Settings.switcherPreviews.toggle()
            // Prompts (or opens System Settings) the first time; until granted, the preview shows the app icon.
            if Settings.switcherPreviews && !Thumbnails.shared.hasPermission { CGRequestScreenCaptureAccess() }
        }
        item.isEnabledWhen = { Settings.enabled && !Settings.showThumbnails }
        return item
    }

    /// The thumbnail view: needs Screen Recording, so choosing it asks for that, and says so until it's granted.
    private func thumbnailsItem() -> ActionItem {
        let item = ActionItem("Show Window Thumbnails", indent: 3) {
            Settings.showThumbnails = true
            // Prompts (or opens System Settings) the first time; until granted, tiles show app icons.
            if !Thumbnails.shared.hasPermission { CGRequestScreenCaptureAccess() }
        }
        item.update = { item in
            item.state = Settings.showThumbnails ? .on : .off
            item.title = Settings.showThumbnails && !Thumbnails.shared.hasPermission
                ? "Show Window Thumbnails (needs Screen Recording permission)"
                : "Show Window Thumbnails"
        }
        return item
    }

    /// A submenu of mutually exclusive `choices` (title, value), with `current` checked.
    private func choiceMenu(_ title: String, choices: [(String, String)], current: @escaping () -> String,
                            choose: @escaping (String) -> Void) -> NSMenuItem {
        let submenu = NSMenu()
        for (choiceTitle, value) in choices {
            submenu.addItem(ActionItem(choiceTitle, isOn: { current() == value }) { choose(value) })
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func launchAtLoginItem() -> ActionItem {
        let item = ActionItem("Launch at Login") { Self.toggleLaunchAtLogin() }
        item.update = { item in
            switch SMAppService.mainApp.status {
            case .enabled:
                item.state = .on
                item.title = "Launch at Login"
            case .requiresApproval:
                item.state = .mixed
                item.title = "Launch at Login (approve in System Settings)"
            default:
                item.state = .off
                item.title = "Launch at Login"
            }
        }
        return item
    }

    private static func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nTip: run CmdTab from /Applications."
            NSApp.activate()
            alert.runModal()
        }
    }

    private func accessibilityItem() -> ActionItem {
        let item = ActionItem("") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        item.update = { item in
            let trusted = AXIsProcessTrusted()
            item.title = trusted ? "Accessibility Permission: Granted" : "Grant Accessibility Permission…"
            item.state = trusted ? .on : .off
        }
        return item
    }
}
