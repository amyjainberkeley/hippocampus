// SPDX-License-Identifier: TBD-private
import Darwin
import Foundation

public struct CaptureConsentState: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let generation: String?
    public let ownerProcessID: Int32
    public let ownerStartTimeUs: UInt64

    public init(
        enabled: Bool,
        generation: String?,
        ownerProcessID: Int32,
        ownerStartTimeUs: UInt64
    ) {
        self.enabled = enabled
        self.generation = generation
        self.ownerProcessID = ownerProcessID
        self.ownerStartTimeUs = ownerStartTimeUs
    }
}

public protocol CaptureConsentControlling: Sendable {
    func enable(generationID: String) throws
    func disable() throws
}

public enum CaptureConsentError: LocalizedError, Equatable {
    case appGroupUnavailable
    case ownerIdentityUnavailable

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "Safari capture is unavailable because the signed App Group container could not be opened."
        case .ownerIdentityUnavailable:
            return "Safari capture is unavailable because the app process identity could not be verified."
        }
    }
}

/// File-backed capture authority shared with the Safari extension.
/// Missing, malformed, disabled, or dead-owner state always means off.
public final class CaptureConsentAuthority: CaptureConsentControlling, @unchecked Sendable {
    public static let filename = "capture-consent.json"

    private let stateURL: URL?
    private let ownerProcessID: Int32
    private let ownerStartTimeUs: UInt64?

    public convenience init() {
        let container = AppGroupIdentity.identifier.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
        self.init(
            stateURL: container?.appendingPathComponent(Self.filename),
            ownerProcessID: ProcessInfo.processInfo.processIdentifier,
            ownerStartTimeUs: Self.processStartTimeUs(
                ProcessInfo.processInfo.processIdentifier
            )
        )
    }

    package init(stateURL: URL, ownerProcessID: Int32, ownerStartTimeUs: UInt64) {
        self.stateURL = stateURL
        self.ownerProcessID = ownerProcessID
        self.ownerStartTimeUs = ownerStartTimeUs
    }

    package init(stateURL: URL?, ownerProcessID: Int32, ownerStartTimeUs: UInt64?) {
        self.stateURL = stateURL
        self.ownerProcessID = ownerProcessID
        self.ownerStartTimeUs = ownerStartTimeUs
    }

    public func enable(generationID: String) throws {
        guard let stateURL else { throw CaptureConsentError.appGroupUnavailable }
        guard let ownerStartTimeUs else {
            throw CaptureConsentError.ownerIdentityUnavailable
        }
        try write(CaptureConsentState(
            enabled: true,
            generation: generationID,
            ownerProcessID: ownerProcessID,
            ownerStartTimeUs: ownerStartTimeUs
        ), to: stateURL)
    }

    public func disable() throws {
        guard let stateURL else { return }
        try write(CaptureConsentState(
            enabled: false,
            generation: nil,
            ownerProcessID: ownerProcessID,
            ownerStartTimeUs: ownerStartTimeUs ?? 0
        ), to: stateURL)
    }

    private func write(_ state: CaptureConsentState, to stateURL: URL) throws {
        let data = try JSONEncoder().encode(state)
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: stateURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )
    }

    package static func readState(at url: URL) throws -> CaptureConsentState {
        try JSONDecoder().decode(CaptureConsentState.self, from: Data(contentsOf: url))
    }

    package static func allowsCapture(
        state: CaptureConsentState?,
        ownerIdentityMatches: (Int32, UInt64) -> Bool = ownerProcessIdentityMatches
    ) -> Bool {
        guard let state,
              state.enabled,
              state.generation?.isEmpty == false,
              state.ownerStartTimeUs > 0,
              ownerIdentityMatches(state.ownerProcessID, state.ownerStartTimeUs)
        else { return false }
        return true
    }

    private static func ownerProcessIdentityMatches(
        _ processID: Int32,
        _ expectedStartTimeUs: UInt64
    ) -> Bool {
        processStartTimeUs(processID) == expectedStartTimeUs
    }

    package static func processStartTimeUs(_ processID: Int32) -> UInt64? {
        guard processID > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, $0, Int32(size))
        }
        guard result == Int32(size) else { return nil }
        let seconds = info.pbi_start_tvsec.multipliedReportingOverflow(by: 1_000_000)
        guard !seconds.overflow else { return nil }
        let total = seconds.partialValue.addingReportingOverflow(info.pbi_start_tvusec)
        return total.overflow ? nil : total.partialValue
    }
}

package struct NoopCaptureConsentAuthority: CaptureConsentControlling {
    package func enable(generationID: String) throws { _ = generationID }
    package func disable() throws {}
}
