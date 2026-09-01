// SPDX-License-Identifier: TBD-private
import Foundation

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

    private struct Payload: Codable {
        let generation: String
        let captureEnabled: Bool

        private enum CodingKeys: String, CodingKey {
            case generation
            case captureEnabled = "capture_enabled"
        }
    }

    public init(fileURL: URL, generation: String, captureEnabled: Bool) {
        self.fileURL = fileURL
        self.generation = generation
        self.captureEnabled = captureEnabled
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
        guard Self.isValidGeneration(generation) else { throw HelperReadinessError.invalidGeneration }
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw HelperReadinessError.existingReceipt
        }
        let data = try JSONEncoder().encode(Payload(
            generation: generation,
            captureEnabled: captureEnabled
        ))
        try data.write(to: fileURL, options: [.atomic, .withoutOverwriting])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
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
            captureEnabled: decoded.captureEnabled
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
