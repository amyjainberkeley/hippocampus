import Foundation
import ScreenCaptureKit

/// Decides whether a window stream's stop is just its window closing.
///
/// A stream bound to one window ends with `noCaptureSource` the moment that
/// window closes. Capture is not broken: the rebind task installs a stream for
/// whatever is focused next. The helper used to exit and restart on every
/// such stop, reloading the OCR worker each time. Only a run of these stops
/// back to back, which a closing window cannot explain, is still a failure.
public struct ClosedWindowBudget: Sendable, Equatable {
    public static let limit = 6
    public static let windowUs: UInt64 = 10_000_000

    private var recentUs: [UInt64] = []

    public init() {}

    /// Whether `error` reports that the captured window is gone.
    public static func isClosedWindow(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain
            && error.code == SCStreamError.Code.noCaptureSource.rawValue
    }

    /// Whether `error` reports a stop of a stream that is not running. Such a
    /// stream has no pixels left to stop.
    public static func isAlreadyStopped(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain
            && error.code == SCStreamError.Code.attemptToStopStreamState.rawValue
    }

    /// Whether this stop can be absorbed by rebinding. False once `limit`
    /// stops have landed within `windowUs`.
    public mutating func absorb(nowUs: UInt64) -> Bool {
        recentUs.removeAll { nowUs < $0 || nowUs - $0 > Self.windowUs }
        recentUs.append(nowUs)
        return recentUs.count < Self.limit
    }
}

/// Spaces out attempts to bind a focused window that cannot be bound: it has
/// closed, is off screen, or belongs to an excluded app. Without this the
/// 200 ms focus poll lists every shareable window five times a second for as
/// long as that window stays focused. A new focused window is tried at once.
public struct RebindRetryPacing: Sendable, Equatable {
    public static let retryIntervalUs: UInt64 = 2_000_000

    private var refusedGeneration: UInt64?
    private var refusedAtUs: UInt64 = 0

    public init() {}

    public func admit(generation: UInt64, nowUs: UInt64) -> Bool {
        guard refusedGeneration == generation else { return true }
        return nowUs >= refusedAtUs && nowUs - refusedAtUs >= Self.retryIntervalUs
    }

    /// Record how an attempt for `generation` ended.
    public mutating func record(generation: UInt64, installed: Bool, nowUs: UInt64) {
        if installed {
            refusedGeneration = nil
        } else {
            refusedGeneration = generation
            refusedAtUs = nowUs
        }
    }
}
