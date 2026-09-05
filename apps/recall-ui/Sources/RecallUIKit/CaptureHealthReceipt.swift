import Foundation

/// Content-free receipt written by the capture agent after committed screen writes.
public struct CaptureHealthReceipt: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let updatedAt: Date
    public let lastStoredFrameAt: Date?
    public let storedFrameCount: UInt64
    public let storedScreenshotCount: UInt64
    public let suppressionReason: String?
    public let blockedReason: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", updatedAt = "updated_at"
        case lastStoredFrameAt = "last_stored_frame_at", storedFrameCount = "stored_frame_count"
        case storedScreenshotCount = "stored_screenshot_count"
        case suppressionReason = "suppression_reason", blockedReason = "blocked_reason"
    }

    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid receipt date"))
        }
        let receipt = try decoder.decode(Self.self, from: data)
        guard receipt.schemaVersion == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported capture receipt"))
        }
        return receipt
    }

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) async -> Self? {
        // A development database must never borrow the real user's capture health.
        let directory = environment["MCI_DB_PATH"].map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MCI")
        return await Task.detached(priority: .utility) { () -> CaptureHealthReceipt? in
            let url = directory.appendingPathComponent("capture-status.json")
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 16_385), data.count <= 16_384 else { return nil }
            return try? decode(data)
        }.value
    }

    public func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) > 90 || updatedAt.timeIntervalSince(now) > 30
    }

    public var stateLabel: String {
        if blockedReason != nil { return "Capture blocked" }
        if suppressionReason != nil { return "Capture withheld" }
        return storedFrameCount == 0 ? "No screen writes yet" : "Screen memory saved"
    }
}

public enum MemorySourceKind {
    public static func label(_ sourceKind: String?) -> String {
        switch sourceKind {
        case "screen_ocr": return "Screen capture"
        case "browser_page": return "Browser page"
        case "browser_page_with_ocr": return "Browser page + screen text"
        case "transcript_import": return "Imported transcript"
        case "structured_app": return "App record"
        case "mcp_resource": return "MCP resource"
        default: return "Unknown source"
        }
    }
}
