import Foundation

/// Content-free storage evidence, atomically published by the Rust agent.
public struct CaptureStatusReceipt: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let updatedAt: Date
    public let lastStoredFrameAt: Date?
    public let storedFrameCount: Int
    public let storedScreenshotCount: Int
    public let suppressionReason: String?
    public let blockedReason: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case updatedAt = "updated_at"
        case lastStoredFrameAt = "last_stored_frame_at"
        case storedFrameCount = "stored_frame_count"
        case storedScreenshotCount = "stored_screenshot_count"
        case suppressionReason = "suppression_reason"
        case blockedReason = "blocked_reason"
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI/capture-status.json")
    }

    public static func read(at url: URL = defaultURL) -> CaptureStatusReceipt? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536 else { return nil }
        return try? decode(data)
    }

    public static func decode(_ data: Data) throws -> CaptureStatusReceipt {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = parseTimestamp(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp")
            }
            return date
        }
        let receipt = try decoder.decode(Self.self, from: data)
        guard receipt.schemaVersion == 1,
              receipt.storedFrameCount >= 0, receipt.storedScreenshotCount >= 0,
              receipt.storedFrameCount == 0 || receipt.lastStoredFrameAt != nil,
              receipt.lastStoredFrameAt.map({ $0 <= receipt.updatedAt }) ?? true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return receipt
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

/// The one button that goes with a status, the same in the menu, Ask's
/// footer and Preferences (spec-shell S2, product critique 11).
public enum CaptureStatusAction: Equatable, Sendable {
    case pause
    case resume
    case turnOn
    case openSystemSettings(TCCRevokedReason)
    /// Restart remembering now (`ProcessSupervisor.retryNow()`).
    case tryAgain
    /// After a failed stop, quitting is the one sure way to stop.
    case quit
    /// Before setup, the only way on is onboarding's Start Remembering.
    case finishSetup

    public var title: String {
        switch self {
        case .pause: return "Pause"
        case .resume: return "Resume"
        case .turnOn: return "Turn On"
        case .openSystemSettings: return "Open System Settings…"
        case .tryAgain: return "Try Again"
        case .quit: return "Quit Hippocampus"
        case .finishSetup: return "Finish Setup…"
        }
    }
}
