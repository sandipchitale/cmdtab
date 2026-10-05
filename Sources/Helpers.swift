import Foundation

/// `index` moved by `delta`, wrapping around a list of `count` items.
func wrapped(_ index: Int, by delta: Int, count: Int) -> Int {
    ((index + delta) % count + count) % count
}

/// Runs `action` on the main queue after each of `delays` (seconds): for state that settles a moment after a change.
func afterEach(_ delays: [TimeInterval], _ action: @escaping @MainActor () -> Void) {
    for delay in delays {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
    }
}

/// `index` moved by `delta` rows in a grid of `columns`, or nil if that falls outside the `count` items.
func movedRows(_ index: Int, by delta: Int, columns: Int, count: Int) -> Int? {
    let target = index + delta * columns
    return (0..<count).contains(target) ? target : nil
}
