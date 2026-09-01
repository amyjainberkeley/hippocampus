import Foundation

public struct KeyframeEvidenceCandidate: Sendable, Equatable {
    public let captureOrdinal: UInt64
    public let focusedWindowId: UInt32
    public let dhash: DHash
    public let monotonicNanoseconds: UInt64

    public init(
        captureOrdinal: UInt64,
        focusedWindowId: UInt32,
        dhash: DHash,
        monotonicNanoseconds: UInt64
    ) {
        self.captureOrdinal = captureOrdinal
        self.focusedWindowId = focusedWindowId
        self.dhash = dhash
        self.monotonicNanoseconds = monotonicNanoseconds
    }
}

public struct KeyframePolicy: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case first
        case windowChanged
        case materialChange
        case maximumSilence
        case skip

        public var shouldRetain: Bool { self != .skip }
    }

    public static let `default` = KeyframePolicy(
        materialDistance: 12,
        maxSilenceNanoseconds: 5 * 60 * 1_000_000_000
    )

    public let materialDistance: Int
    public let maxSilenceNanoseconds: UInt64

    public init(materialDistance: Int, maxSilenceNanoseconds: UInt64) {
        precondition((0...64).contains(materialDistance))
        precondition(maxSilenceNanoseconds > 0)
        self.materialDistance = materialDistance
        self.maxSilenceNanoseconds = maxSilenceNanoseconds
    }

    public func decision(
        previous: KeyframeEvidenceCandidate?,
        current: KeyframeEvidenceCandidate
    ) -> Decision {
        guard let previous else { return .first }
        guard current.captureOrdinal > previous.captureOrdinal else { return .skip }
        if current.focusedWindowId != previous.focusedWindowId {
            return .windowChanged
        }
        if current.dhash.distance(to: previous.dhash) >= materialDistance {
            return .materialChange
        }
        if current.monotonicNanoseconds >= previous.monotonicNanoseconds,
           current.monotonicNanoseconds - previous.monotonicNanoseconds >= maxSilenceNanoseconds
        {
            return .maximumSilence
        }
        return .skip
    }
}
