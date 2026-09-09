import Foundation

public enum MeasuredActivityState: UInt8, Sendable {
    case unknown = 0
    case inputActive = 1
    case inputIdle = 2
}

public struct MeasuredActivityInterval: Sendable, Equatable {
    public let startUs: UInt64
    public let endUs: UInt64
    public let state: MeasuredActivityState
    public let appBundleId: String?
    public let captureGeneration: String
}

struct ActivityObservation: Sendable {
    let tsUs: UInt64
    let uptimeNs: UInt64
    let focusGeneration: UInt64
    let appBundleId: String?
    let state: UserActivityState
    let admitted: Bool
}

/// Measures adjacent samples, never screenshot spans or unobserved downtime.
struct ActivityIntervalSampler {
    let captureGeneration: String
    private var previous: ActivityObservation?
    private var lastEmittedEndUs: UInt64 = 0

    init(captureGeneration: String) {
        self.captureGeneration = captureGeneration
    }

    mutating func sample(_ current: ActivityObservation) -> MeasuredActivityInterval? {
        defer { previous = current }
        // Keep the emitted boundary across clock discontinuities, while taking
        // fresh adjacent observations for recovery. Never clip a measured pair.
        guard let prior = previous, prior.tsUs > 0, prior.tsUs >= lastEmittedEndUs,
              current.tsUs > prior.tsUs, current.uptimeNs > prior.uptimeNs else { return nil }
        let wallUs = current.tsUs - prior.tsUs
        let monotonicUs = (current.uptimeNs - prior.uptimeNs) / 1_000
        guard wallUs <= 5_000_000, monotonicUs <= 5_000_000,
              max(wallUs, monotonicUs) - min(wallUs, monotonicUs) <= 250_000 else { return nil }
        let agrees = prior.admitted && current.admitted
            && prior.focusGeneration == current.focusGeneration
            && prior.appBundleId == current.appBundleId
            && current.appBundleId.map(Self.validBundleID) == true
            && prior.state == current.state && current.state != .unknown
        let state: MeasuredActivityState = !agrees ? .unknown
            : (current.state == .active ? .inputActive : .inputIdle)
        lastEmittedEndUs = current.tsUs
        return MeasuredActivityInterval(startUs: prior.tsUs, endUs: current.tsUs, state: state,
                                        appBundleId: agrees ? current.appBundleId : nil,
                                        captureGeneration: captureGeneration)
    }

    private static func validBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 255 && parts.count >= 2 && parts.allSatisfy { part in
            let bytes = Array(part.utf8)
            return bytes.first.map(isAlphanumeric) == true && bytes.last.map(isAlphanumeric) == true
                && bytes.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45
            }
        }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}
