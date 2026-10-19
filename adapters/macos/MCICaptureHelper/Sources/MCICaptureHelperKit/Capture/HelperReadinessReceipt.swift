// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

public enum HelperReadinessError: Error, Sendable, Equatable {
    case incompleteArguments
    case invalidGeneration
    case existingReceipt
    case invalidReceipt
}

extension HelperReadinessError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .incompleteArguments: "Both --readiness-file and --generation are required."
        case .invalidGeneration: "The helper process generation is invalid."
        case .existingReceipt: "The helper readiness receipt already exists."
        case .invalidReceipt: "The helper readiness receipt is invalid."
        }
    }
}

/// Content-free receipt written only after helper startup is complete.
public struct HelperReadinessReceipt: Sendable, Equatable {
    public let fileURL: URL
    public let generation: String
    public let captureEnabled: Bool
    /// The permissions macOS had off as this generation started, by surface
    /// name ("screenRecording", "accessibility"). The session is paused on
    /// them and starts reading by itself once they are allowed, so the app
    /// does not take a turn-on for done while one is off. Content-free, like
    /// the `helper_health tcc_revoked=` breadcrumbs; empty without capture.
    public let permissionsOff: [String]

    private struct Payload: Codable {
        let generation: String
        let captureEnabled: Bool
        /// Absent from an older helper's receipt.
        let permissionsOff: [String]?

        private enum CodingKeys: String, CodingKey {
            case generation
            case captureEnabled = "capture_enabled"
            case permissionsOff = "permissions_off"
        }
    }

    public init(fileURL: URL, generation: String, captureEnabled: Bool, permissionsOff: [String] = []) {
        self.fileURL = fileURL
        self.generation = generation
        self.captureEnabled = captureEnabled
        self.permissionsOff = permissionsOff
    }

    public static func parse(arguments: [String]) throws -> HelperReadinessReceipt? {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }
        let path = value(after: "--readiness-file")
        let generation = value(after: "--generation")
        if path == nil, generation == nil { return nil }
        guard let path, let generation else { throw HelperReadinessError.incompleteArguments }
        guard Self.isValidGeneration(generation) else { throw HelperReadinessError.invalidGeneration }
        return HelperReadinessReceipt(
            fileURL: URL(fileURLWithPath: path),
            generation: generation,
            captureEnabled: arguments.contains(CaptureLaunchOptions.captureFlag)
        )
    }

    public func publish() throws {
        try publish(permissionsOff: permissionsOff)
    }

    /// Publishes the receipt with the permissions the session found off as
    /// it started (`SCStreamCaptureSession.permissionsOff()`).
    public func publish(permissionsOff: [String]) throws {
        guard Self.isValidGeneration(generation) else { throw HelperReadinessError.invalidGeneration }
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw HelperReadinessError.existingReceipt
        }
        let data = try JSONEncoder().encode(Payload(
            generation: generation,
            captureEnabled: captureEnabled,
            permissionsOff: Array(Set(permissionsOff)).sorted()
        ))
        let temporaryURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        // Foundation traps when `.atomic` and `.withoutOverwriting` are
        // combined. Prepare a complete, private inode off-path, then publish
        // it with link(2), whose no-replacement behavior is atomic.
        try data.write(to: temporaryURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryURL.path
        )
        let result = temporaryURL.path.withCString { source in
            fileURL.path.withCString { destination in
                Darwin.link(source, destination)
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST { throw HelperReadinessError.existingReceipt }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    public static func read(from fileURL: URL) throws -> HelperReadinessReceipt {
        let decoded = try JSONDecoder().decode(
            Payload.self,
            from: Data(contentsOf: fileURL)
        )
        guard isValidGeneration(decoded.generation) else {
            throw HelperReadinessError.invalidReceipt
        }
        return HelperReadinessReceipt(
            fileURL: fileURL,
            generation: decoded.generation,
            captureEnabled: decoded.captureEnabled,
            permissionsOff: decoded.permissionsOff ?? []
        )
    }

    private static func isValidGeneration(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.utf8.allSatisfy {
                (48...57).contains($0)
                    || (65...90).contains($0)
                    || (97...122).contains($0)
                    || $0 == 45
            }
    }
}
