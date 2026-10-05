import AppKit
import ScreenCaptureKit

/// Window snapshots for the thumbnail view. Needs Screen Recording permission; without it tiles fall back to app icons.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    private var cache: [CGWindowID: CGImage] = [:]
    /// Bumped by each refresh, so a superseded one stops (and its snapshots aren't cached or reported).
    private var generation = 0
    private var inFlight: Task<Void, Never>?
    /// The windows ScreenCaptureKit lists, fetched once per switcher or Dock session instead of for every refresh.
    private var content: SCShareableContent?

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func cached(_ id: CGWindowID) -> CGImage? { cache[id] }

    /// Drops the snapshots of windows other than `ids`. The switcher calls this, since it lists every window.
    func retain(only ids: [CGWindowID]) {
        let keep = Set(ids)
        cache = cache.filter { keep.contains($0.key) }
    }

    /// Forgets the listed windows, when the switcher or Dock closes: the next session lists them afresh.
    func endSession() { content = nil }

    /// Captures fresh snapshots of `ids`, reporting each as it arrives. Windows that can't be captured right now
    /// (minimized, hidden apps) keep their last snapshot. A newer refresh cancels this one's unfinished captures.
    func refresh(_ ids: [CGWindowID], onImage: @escaping (CGWindowID, CGImage) -> Void) {
        let wanted = Set(ids)
        guard hasPermission else { return }
        generation += 1
        let gen = generation
        inFlight?.cancel()

        inFlight = Task {
            let content: SCShareableContent
            if let cached = self.content {
                content = cached
            } else {
                guard let fetched = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
                      gen == self.generation else { return }
                self.content = fetched
                content = fetched
            }
            await withTaskGroup(of: Void.self) { group in
                for window in content.windows where wanted.contains(window.windowID) {
                    group.addTask { @MainActor in
                        guard let image = await Self.capture(window), !Task.isCancelled, gen == self.generation else { return }
                        self.cache[window.windowID] = image
                        onImage(window.windowID, image)
                    }
                }
            }
        }
    }

    private static func capture(_ window: SCWindow) async -> CGImage? {
        let size = window.frame.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(640 / size.width, 400 / size.height, 2)

        let config = SCStreamConfiguration()
        config.width = max(1, Int(size.width * scale))
        config.height = max(1, Int(size.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
