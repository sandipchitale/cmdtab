import AppKit

/// A menu item that runs a closure. It can also keep its own title and state up to date (`update`, run whenever its
/// menu opens) and decide whether it's enabled (`isEnabledWhen`, asked when its menu enables items automatically).
@MainActor
final class ActionItem: NSMenuItem, NSMenuItemValidation {
    private let handler: () -> Void
    var update: ((NSMenuItem) -> Void)?
    var isEnabledWhen: (() -> Bool)?

    init(_ title: String, indent: Int = 0, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
        indentationLevel = indent
    }

    /// An item checked while `isOn` holds.
    convenience init(_ title: String, indent: Int = 0, isOn: @escaping () -> Bool, handler: @escaping () -> Void) {
        self.init(title, indent: indent, handler: handler)
        update = { $0.state = isOn() ? .on : .off }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isEnabledWhen?() ?? true }
}

extension NSMenu {
    /// Brings every `ActionItem` in this menu and its submenus up to date.
    @MainActor
    func updateActionItems() {
        for item in items {
            (item as? ActionItem)?.update?(item)
            item.submenu?.updateActionItems()
        }
    }
}
