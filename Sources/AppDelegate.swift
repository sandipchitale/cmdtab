import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu?
    private let controller = SwitcherController()
    private let dock = DockController()
    private lazy var tap = HotkeyTap(controller: controller, dock: dock)
    private let greenButtonTap = GreenButtonTap()
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        controller.onFinished = { [weak self] in self?.tap.active = false }
        statusMenu = StatusMenu(onSwitcherToggled: { [weak self] in self?.applyEnabled() },
                                onDockTurnedOff: { [weak self] in self?.dock.close() })

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
    }

    /// While we're enabled the system switcher is off, otherwise it would pop up alongside ours.
    private func applyEnabled() {
        NativeSwitcher.setEnabled(!(Settings.enabled && tap.isRunning))
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
}
