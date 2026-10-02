import AppKit
import ServiceManagement

enum Settings {
    private static let d = UserDefaults.standard

    static func register() {
        d.register(defaults: ["enabled": true, "includeMinimized": true, "includeHiddenApps": true, "showThumbnails": false, "appearance": "system", "greenButtonZooms": true])
    }

    static var enabled: Bool {
        get { d.bool(forKey: "enabled") }
        set { d.set(newValue, forKey: "enabled") }
    }
    static var includeMinimized: Bool {
        get { d.bool(forKey: "includeMinimized") }
        set { d.set(newValue, forKey: "includeMinimized") }
    }
    static var includeHiddenApps: Bool {
        get { d.bool(forKey: "includeHiddenApps") }
        set { d.set(newValue, forKey: "includeHiddenApps") }
    }
    static var showThumbnails: Bool {
        get { d.bool(forKey: "showThumbnails") }
        set { d.set(newValue, forKey: "showThumbnails") }
    }
    /// Switcher panel appearance: "system", "light", or "dark".
    static var appearance: String {
        get { d.string(forKey: "appearance") ?? "system" }
        set { d.set(newValue, forKey: "appearance") }
    }
    /// Clicking a window's green button toggles it between filling the screen and its previous frame, instead of entering full screen.
    static var greenButtonZooms: Bool {
        get { d.bool(forKey: "greenButtonZooms") }
        set { d.set(newValue, forKey: "greenButtonZooms") }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = SwitcherController()
    private lazy var tap = HotkeyTap(controller: controller)
    private let greenButtonTap = GreenButtonTap()
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let minimizedItem = NSMenuItem(title: "Include Minimized Windows", action: #selector(toggleMinimized), keyEquivalent: "")
    private let hiddenItem = NSMenuItem(title: "Include Windows of Hidden Apps", action: #selector(toggleHidden), keyEquivalent: "")
    private let iconsItem = NSMenuItem(title: "Show App Icons", action: #selector(showIcons), keyEquivalent: "")
    private let thumbnailsItem = NSMenuItem(title: "Show Window Thumbnails", action: #selector(showThumbnails), keyEquivalent: "")
    private let appearanceItems = [("System", "system"), ("Light", "light"), ("Dark", "dark")].map { title, value in
        let item = NSMenuItem(title: title, action: #selector(setAppearance(_:)), keyEquivalent: "")
        item.representedObject = value
        return item
    }
    private let greenButtonItem = NSMenuItem(title: "Green Button Toggles Maximize Instead of Full Screen", action: #selector(toggleGreenButton), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        installSignalHandlers()
        controller.onFinished = { [weak self] in self?.tap.active = false }
        buildStatusItem()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            startEngine()
        } else {
            // Wait for the user to flip the switch in System Settings, then start without a relaunch.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    self?.permissionTimer?.invalidate()
                    self?.permissionTimer = nil
                    self?.startEngine()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NativeSwitcher.setEnabled(true)
    }

    private func startEngine() {
        WindowManager.shared.start()
        if tap.start() {
            applyEnabled()
        } else {
            NSLog("CmdTab: failed to create event tap")
        }
        if !greenButtonTap.start() { NSLog("CmdTab: failed to create green button event tap") }
        updateMenu()
    }

    /// While we're enabled the system switcher is off, otherwise it would pop up alongside ours.
    private func applyEnabled() {
        NativeSwitcher.setEnabled(!(Settings.enabled && tap.isRunning))
        statusItem.button?.appearsDisabled = !Settings.enabled
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                NativeSwitcher.setEnabled(true)
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: - Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "CmdTab")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "CmdTab — Windows-style Cmd+Tab"

        let menu = NSMenu()
        menu.delegate = self
        let header = NSMenuItem(title: "CmdTab — Windows-style window switcher", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(enabledItem)
        menu.addItem(minimizedItem)
        menu.addItem(hiddenItem)
        menu.addItem(.separator())
        menu.addItem(iconsItem)
        menu.addItem(thumbnailsItem)
        let appearanceMenu = NSMenu()
        for item in appearanceItems {
            item.target = self
            appearanceMenu.addItem(item)
        }
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)
        menu.addItem(.separator())
        menu.addItem(greenButtonItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit CmdTab", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
        updateMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updateMenu() }

    private func updateMenu() {
        enabledItem.state = Settings.enabled ? .on : .off
        minimizedItem.state = Settings.includeMinimized ? .on : .off
        hiddenItem.state = Settings.includeHiddenApps ? .on : .off
        iconsItem.state = Settings.showThumbnails ? .off : .on
        thumbnailsItem.state = Settings.showThumbnails ? .on : .off
        for item in appearanceItems {
            item.state = item.representedObject as? String == Settings.appearance ? .on : .off
        }
        greenButtonItem.state = Settings.greenButtonZooms ? .on : .off
        thumbnailsItem.title = Settings.showThumbnails && !Thumbnails.shared.hasPermission
            ? "Show Window Thumbnails (needs Screen Recording permission)"
            : "Show Window Thumbnails"

        switch SMAppService.mainApp.status {
        case .enabled:
            loginItem.state = .on
            loginItem.title = "Launch at Login"
        case .requiresApproval:
            loginItem.state = .mixed
            loginItem.title = "Launch at Login (approve in System Settings)"
        default:
            loginItem.state = .off
            loginItem.title = "Launch at Login"
        }

        let trusted = AXIsProcessTrusted()
        permissionItem.title = trusted ? "Accessibility Permission: Granted" : "Grant Accessibility Permission…"
        permissionItem.state = trusted ? .on : .off
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        applyEnabled()
        updateMenu()
    }

    @objc private func toggleMinimized() {
        Settings.includeMinimized.toggle()
        updateMenu()
    }

    @objc private func toggleHidden() {
        Settings.includeHiddenApps.toggle()
        updateMenu()
    }

    @objc private func showIcons() {
        Settings.showThumbnails = false
        updateMenu()
    }

    @objc private func showThumbnails() {
        Settings.showThumbnails = true
        // Prompts (or opens System Settings) the first time; until granted, tiles show app icons.
        if !Thumbnails.shared.hasPermission { CGRequestScreenCaptureAccess() }
        updateMenu()
    }

    @objc private func setAppearance(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        Settings.appearance = value
        updateMenu()
    }

    @objc private func toggleGreenButton() {
        Settings.greenButtonZooms.toggle()
        updateMenu()
    }

    @objc private func toggleLaunchAtLogin() {
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
        updateMenu()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NativeSwitcher.setEnabled(true)
        NSApp.terminate(nil)
    }
}
