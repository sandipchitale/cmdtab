import AppKit
import ScreenCaptureKit

/// Window snapshots for the thumbnail view. Needs Screen Recording permission; without it tiles fall back to app icons.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    private var cache: [CGWindowID: CGImage] = [:]
    private var generation = 0

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func cached(_ id: CGWindowID) -> CGImage? { cache[id] }

    /// Captures fresh snapshots of `ids`, reporting each as it arrives. Windows that can't be captured right now
    /// (minimized, hidden apps) keep their last snapshot.
    func refresh(_ ids: [CGWindowID], onImage: @escaping (CGWindowID, CGImage) -> Void) {
        let wanted = Set(ids)
        cache = cache.filter { wanted.contains($0.key) }
        guard hasPermission else { return }
        generation += 1
        let gen = generation

        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            for window in content.windows where wanted.contains(window.windowID) {
                Task {
                    guard let image = await Self.capture(window), gen == self.generation else { return }
                    self.cache[window.windowID] = image
                    onImage(window.windowID, image)
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
