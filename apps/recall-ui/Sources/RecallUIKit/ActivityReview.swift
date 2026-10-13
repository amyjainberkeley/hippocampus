import Foundation

/// Measured input state over a half-open foreground interval. Never derived from captures.
public struct ActivityInterval: Codable, Equatable, Sendable {
    public let startUs: UInt64
    public let endUs: UInt64
    public let state: String
    public let appBundleId: String?

    public init(startUs: UInt64, endUs: UInt64, state: String, appBundleId: String?) {
        self.startUs = startUs
        self.endUs = endUs
        self.state = state
        self.appBundleId = appBundleId
    }

    enum CodingKeys: String, CodingKey {
        case startUs = "start_us", endUs = "end_us", state, appBundleId = "app_bundle_id"
    }
}

public struct ActivityPage: Codable, Equatable, Sendable {
    public let intervals: [ActivityInterval]
    public let truncated: Bool

    public init(intervals: [ActivityInterval], truncated: Bool) {
        self.intervals = intervals
        self.truncated = truncated
    }
}

public enum ActivityReadError: Error { case unavailable }
