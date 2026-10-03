import AppKit

/// One tile of the Option+Tab Dock.
struct DockItem {
    enum Kind {
        /// `running` is nil for a pinned or recent app that isn't open.
        case app(url: URL, bundleID: String?, running: NSRunningApplication?)
        case folder(URL)
        case trash
    }

    let kind: Kind
    let name: String
    /// A Dock spacer or section divider in front of this item.
    var separator: TileSeparator?

    var runningApp: NSRunningApplication? {
        if case .app(_, _, let running) = kind { return running }
        return nil
    }

    /// Loaded when drawn, so listing the Dock (e.g. just to size the switcher like it) stays cheap.
    var icon: NSImage {
        switch kind {
        case .app(let url, _, let running): return running?.icon ?? NSWorkspace.shared.icon(forFile: url.path)
        case .folder(let url): return NSWorkspace.shared.icon(forFile: url.path)
        case .trash: return DockItems.trashIcon()
        }
    }
}

/// Reads what the real Dock shows, in Dock order, from its own preferences (com.apple.dock): pinned apps (with
/// spacers), the recent apps section, running apps that aren't pinned, then folders and stacks, then the Trash.
/// Adapted from WindowRing's DockDiscovery.
enum DockItems {
    static var trashURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") }

    static func current() -> [DockItem] {
        let prefs = UserDefaults(suiteName: "com.apple.dock")
        let myPID = getpid()
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != myPID && !$0.isTerminated
        }
        let runningByBundleID = Dictionary(running.compactMap { app in app.bundleIdentifier.map { ($0, app) } },
                                           uniquingKeysWith: { first, _ in first })
        let runningByURL = Dictionary(running.compactMap { app in app.bundleURL.map { ($0.standardizedFileURL, app) } },
                                      uniquingKeysWith: { first, _ in first })

        var items: [DockItem] = []
        var seen = Set<String>() // bundle ids, or paths for apps without one
        var pending: TileSeparator?

        func add(_ item: DockItem) {
            var item = item
            // A separator only makes sense between two items, and a divider wins over a plain gap.
            if !items.isEmpty { item.separator = pending }
            pending = nil
            items.append(item)
        }

        func addApp(tile: [String: Any]) {
            let bundleID = tile["bundle-identifier"] as? String
            var url = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            if url == nil, let s = (tile["file-data"] as? [String: Any])?["_CFURLString"] as? String { url = URL(string: s) }
            guard let url else { return }
            let id = bundleID ?? Bundle(url: url)?.bundleIdentifier ?? url.path
            guard seen.insert(id).inserted else { return }
            let app = runningByBundleID[id] ?? runningByURL[url.standardizedFileURL]
            let name = tile["file-label"] as? String ?? FileManager.default.displayName(atPath: url.path)
            add(DockItem(kind: .app(url: url, bundleID: bundleID, running: app), name: name))
        }

        func addRunning(_ app: NSRunningApplication) {
            let id = app.bundleIdentifier ?? app.bundleURL?.path ?? "pid:\(app.processIdentifier)"
            guard let url = app.bundleURL, seen.insert(id).inserted else { return }
            add(DockItem(kind: .app(url: url, bundleID: app.bundleIdentifier, running: app),
                         name: app.localizedName ?? url.deletingPathExtension().lastPathComponent))
        }

        func entries(_ key: String) -> [[String: Any]] { prefs?.array(forKey: key) as? [[String: Any]] ?? [] }

        // Finder always leads the Dock; it isn't stored with the pinned apps.
        addApp(tile: ["bundle-identifier": "com.apple.finder", "file-label": "Finder"])

        // Pinned apps, with their spacers.
        for entry in entries("persistent-apps") {
            let type = entry["tile-type"] as? String ?? "file-tile"
            if type.hasSuffix("spacer-tile") {
                if pending == nil { pending = .space }
                continue
            }
            if let tile = entry["tile-data"] as? [String: Any] { addApp(tile: tile) }
        }

        // The recent apps section, which also holds running apps that aren't pinned. Without it, those simply follow
        // the pinned apps.
        let showRecents = prefs?.object(forKey: "show-recents") as? Bool ?? true
        if showRecents { pending = .divider }
        if showRecents {
            for entry in entries("recent-apps") {
                if let tile = entry["tile-data"] as? [String: Any] { addApp(tile: tile) }
            }
        }
        for app in running { addRunning(app) }

        // Folders and stacks, then the Trash, after a divider.
        pending = .divider
        for entry in entries("persistent-others") {
            guard let tile = entry["tile-data"] as? [String: Any],
                  let s = (tile["file-data"] as? [String: Any])?["_CFURLString"] as? String,
                  let url = URL(string: s) else { continue }
            let name = tile["file-label"] as? String ?? FileManager.default.displayName(atPath: url.path)
            add(DockItem(kind: .folder(url), name: name))
        }
        add(DockItem(kind: .trash, name: "Trash"))
        return items
    }

    /// Empty or full, like the Dock's. Reading ~/.Trash can be denied, in which case it shows as empty.
    static func trashIcon() -> NSImage {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: trashURL.path)) ?? []
        let full = contents.contains { $0 != ".DS_Store" }
        return NSImage(named: full ? NSImage.trashFullName : NSImage.trashEmptyName) ?? NSImage()
    }
}
