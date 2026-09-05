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

    public var storedCountsText: String {
        "\(storedFrameCount) saved frames, \(storedScreenshotCount) screenshots"
    }

    public func lastSavedText(relativeTo now: Date = Date()) -> String {
        guard let saved = lastStoredFrameAt else { return "Last saved: none reported" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Last saved: \(formatter.localizedString(for: saved, relativeTo: now))"
    }
}

public enum CaptureStatusAction: Equatable, Sendable {
    case resume
    case start
    case openPermission(TCCRevokedReason)
    case reviewCapture
    case openLogs

    public var title: String {
        switch self {
        case .resume: return "Resume Capture"
        case .start: return "Start Capture"
        case .openPermission: return "Open Permission Settings"
        case .reviewCapture: return "Review Capture Settings"
        case .openLogs: return "Open Capture Logs"
        }
    }

    public var symbol: String {
        switch self {
        case .resume, .start: return "play.fill"
        case .openPermission: return "lock.shield"
        case .reviewCapture: return "slider.horizontal.3"
        case .openLogs: return "doc.text.magnifyingglass"
        }
    }
}
