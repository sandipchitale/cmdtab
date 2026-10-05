import AppKit

/// An app's windows, previewed in a strip under its icon: the Option+Tab Dock's selected app, and Cmd+Tab when it
/// groups windows by app. The keyboard is either on the icons (`selected` nil) or on one of the previews.
@MainActor
final class WindowPreviews {
    private let panels: PanelGroup
    private(set) var windows: [SwitcherWindow] = []
    /// The highlighted preview, or nil while the keyboard is on the icons.
    private(set) var selected: Int?
    private var pending: DispatchWorkItem?

    init(panels: PanelGroup) {
        self.panels = panels
    }

    var isEmpty: Bool { windows.isEmpty }

    var selectedWindow: SwitcherWindow? {
        selected.flatMap { windows.indices.contains($0) ? windows[$0] : nil }
    }

    /// Shows `windows` under tile `index` (or hides the strip if there are none), highlighting preview `selected`.
    /// With `refreshThumbnails`, takes fresh snapshots of them too.
    func show(_ windows: [SwitcherWindow], under index: Int, selected: Int? = nil, refreshThumbnails: Bool) {
        self.windows = windows
        self.selected = selected.flatMap { windows.indices.contains($0) ? $0 : nil }
        redraw(under: index)
        guard refreshThumbnails, !windows.isEmpty else { return }
        Thumbnails.shared.refresh(windows.map(\.id)) { [weak self] id, image in
            self?.panels.setPreviewThumbnail(image, for: id)
        }
    }

    func select(_ i: Int?) {
        guard i.map(windows.indices.contains) ?? true else { return }
        selected = i
        panels.setPreviewSelected(i)
    }

    /// The next or previous preview, wrapping around. Only while one is highlighted.
    func move(_ delta: Int) {
        guard let s = selected, !windows.isEmpty else { return }
        select(wrapped(s, by: delta, count: windows.count))
    }

    /// Drops the highlighted preview's window (it was closed), keeping a neighbor highlighted.
    func removeSelected(under index: Int) {
        guard let s = selected, windows.indices.contains(s) else { return }
        windows.remove(at: s)
        selected = windows.isEmpty ? nil : min(s, windows.count - 1)
        redraw(under: index)
    }

    /// The previews go away now, and `load` runs once the selection has settled, so holding Tab doesn't capture every
    /// app on the way.
    func schedule(_ load: @escaping @MainActor () -> Void) {
        clear()
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            load()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func clear() {
        pending?.cancel()
        pending = nil
        windows = []
        selected = nil
        panels.hidePreviews()
    }

    private func redraw(under index: Int) {
        guard !windows.isEmpty else { return panels.hidePreviews() }
        panels.showPreviews(tiles: windows.map { SwitcherTile(window: $0) }, under: index, selected: selected)
    }
}
