import CoreGraphics
import Foundation

/// Running totals of input events the window server has counted since login.
/// Counts only: which keys were pressed is never read, and reading these
/// counters needs no permission beyond what capture already holds.
public struct InteractionTotals: Sendable, Equatable {
    public var keys: UInt32
    public var clicks: UInt32
    public var scrolls: UInt32
    public var moves: UInt32

    public init(keys: UInt32, clicks: UInt32, scrolls: UInt32, moves: UInt32) {
        self.keys = keys; self.clicks = clicks; self.scrolls = scrolls; self.moves = moves
    }

    /// Read the system counters.
    public static func current() -> InteractionTotals {
        let state = CGEventSourceStateID.combinedSessionState
        func count(_ type: CGEventType) -> UInt32 { CGEventSource.counterForEventType(state, eventType: type) }
        return InteractionTotals(
            keys: count(.keyDown),
            clicks: count(.leftMouseDown) &+ count(.rightMouseDown) &+ count(.otherMouseDown),
            scrolls: count(.scrollWheel),
            moves: count(.mouseMoved) &+ count(.leftMouseDragged) &+ count(.rightMouseDragged)
        )
    }

    /// Events since `earlier`. Counters wrap at 2^32; a decrease larger than a
    /// wrap could explain (a counter reset) reads as nothing.
    public func since(_ earlier: InteractionTotals) -> InteractionTotals {
        func delta(_ now: UInt32, _ then: UInt32) -> UInt32 {
            let d = now &- then
            return d > 1_000_000 ? 0 : d
        }
        return InteractionTotals(keys: delta(keys, earlier.keys), clicks: delta(clicks, earlier.clicks),
                                 scrolls: delta(scrolls, earlier.scrolls), moves: delta(moves, earlier.moves))
    }
}

/// Input counts for one measured interval.
public struct MeasuredInteractionCounts: Sendable, Equatable {
    public let startUs: UInt64
    public let endUs: UInt64
    public let totals: InteractionTotals
}
