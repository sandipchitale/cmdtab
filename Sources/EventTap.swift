import CoreGraphics

/// A session-wide event tap on the main run loop, handing `events` to `handler`, which returns the event to pass on
/// or nil to swallow it. macOS turns a tap off when its callback is too slow; this turns it straight back on, then
/// calls `onReenable`, since events that arrived in the gap are lost.
@MainActor
final class EventTap {
    typealias Handler = (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    private let events: [CGEventType]
    private let handler: Handler
    private let onReenable: () -> Void
    private var tap: CFMachPort?

    init(events: [CGEventType], onReenable: @escaping () -> Void = {}, handler: @escaping Handler) {
        self.events = events
        self.onReenable = onReenable
        self.handler = handler
    }

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { me.handle(type: type, event: event) }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            onReenable()
            return Unmanaged.passUnretained(event)
        }
        return handler(type, event)
    }
}
