// SPDX-License-Identifier: TBD-private

import Foundation
#if os(macOS)
import CoreGraphics
#endif

/// A current input-activity reading for the user's login session.
public protocol UserActivityReading: Sendable {
    /// Returns elapsed seconds, or nil when unavailable, invalid, or known stale.
    /// Consume immediately; the elapsed duration does not encode the sample's age.
    func secondsSinceLastInput() -> TimeInterval?
}

/// Input activity only; this does not establish attention to an application.
public enum UserActivityState: Sendable, Equatable {
    case active
    case idle
    case unknown

    public static let defaultIdleThreshold: TimeInterval = 60

    /// Classifies a fresh reading. The threshold must be finite and nonnegative;
    /// invalid thresholds or readings produce unknown. Zero is a valid threshold.
    public static func classify(
        secondsSinceLastInput: TimeInterval?,
        idleThreshold: TimeInterval = defaultIdleThreshold
    ) -> Self {
        guard idleThreshold.isFinite, idleThreshold >= 0,
              let secondsSinceLastInput,
              secondsSinceLastInput.isFinite, secondsSinceLastInput >= 0
        else {
            return .unknown
        }
        return secondsSinceLastInput >= idleThreshold ? .idle : .active
    }
}

/// Reads the combined session's elapsed time since any keyboard, mouse, or tablet
/// input, including events posted by other event sources in that session.
/// Performs one synchronous Quartz query per call, with no retries or retained
/// samples. Quartz documents neither a timeout guarantee nor an error sentinel.
public struct SystemUserActivityReader: UserActivityReading {
    #if os(macOS)
    private let query: @Sendable (CGEventSourceStateID, CGEventType) -> TimeInterval
    #endif

    public init() {
        #if os(macOS)
        query = { state, eventType in
            CGEventSource.secondsSinceLastEventType(state, eventType: eventType)
        }
        #endif
    }

    #if os(macOS)
    // Keeps validation and query selection testable without observing live input.
    init(query: @escaping @Sendable (CGEventSourceStateID, CGEventType) -> TimeInterval) {
        self.query = query
    }
    #endif

    public func secondsSinceLastInput() -> TimeInterval? {
        #if os(macOS)
        // CGEventTypes.h defines kCGAnyInputEventType as ((CGEventType)(~0)).
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return nil }
        let seconds = query(.combinedSessionState, anyInput)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
        #else
        return nil
        #endif
    }
}
