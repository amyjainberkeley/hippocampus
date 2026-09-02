// SPDX-License-Identifier: TBD-private
import Darwin
import Foundation

public struct CaptureConsentState: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let generation: String?
    public let ownerProcessID: Int32

    public init(enabled: Bool, generation: String?, ownerProcessID: Int32) {
        self.enabled = enabled
        self.generation = generation
        self.ownerProcessID = ownerProcessID
    }
}

public protocol CaptureConsentControlling: Sendable {
    func enable(generationID: String) throws
    func disable() throws
}

/// File-backed capture authority shared with the Safari extension.
/// Missing, malformed, disabled, or dead-owner state always means off.
public final class CaptureConsentAuthority: CaptureConsentControlling, @unchecked Sendable {
    public static let groupID = "group.ai.hippocampus"
    public static let filename = "capture-consent.json"

    private let stateURL: URL?
    private let ownerProcessID: Int32

    public convenience init() {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.groupID
        )
        self.init(
            stateURL: container?.appendingPathComponent(Self.filename),
            ownerProcessID: ProcessInfo.processInfo.processIdentifier
        )
    }

    package init(stateURL: URL, ownerProcessID: Int32) {
        self.stateURL = stateURL
        self.ownerProcessID = ownerProcessID
    }

    private init(stateURL: URL?, ownerProcessID: Int32) {
        self.stateURL = stateURL
        self.ownerProcessID = ownerProcessID
    }

    public func enable(generationID: String) throws {
        try write(CaptureConsentState(
            enabled: true,
            generation: generationID,
            ownerProcessID: ownerProcessID
        ))
    }

    public func disable() throws {
        try write(CaptureConsentState(
            enabled: false,
            generation: nil,
            ownerProcessID: ownerProcessID
        ))
    }

    private func write(_ state: CaptureConsentState) throws {
        // No shared container means the Safari extension cannot write
        // payloads either, so the effective state is already disabled.
        guard let stateURL else { return }
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: [.atomic])
    }

    package static func readState(at url: URL) throws -> CaptureConsentState {
        try JSONDecoder().decode(CaptureConsentState.self, from: Data(contentsOf: url))
    }

    package static func allowsCapture(
        state: CaptureConsentState?,
        ownerIsAlive: (Int32) -> Bool = ownerProcessIsAlive
    ) -> Bool {
        guard let state,
              state.enabled,
              state.generation?.isEmpty == false,
              ownerIsAlive(state.ownerProcessID)
        else { return false }
        return true
    }

    private static func ownerProcessIsAlive(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }
}

package struct NoopCaptureConsentAuthority: CaptureConsentControlling {
    package func enable(generationID: String) throws { _ = generationID }
    package func disable() throws {}
}
