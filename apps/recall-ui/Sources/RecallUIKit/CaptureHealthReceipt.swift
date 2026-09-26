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
        if suppressionReason == "unchanged_screen" || suppressionReason == "deduplicated" {
            return "Screen unchanged"
        }
        if suppressionReason != nil { return "Capture withheld" }
        return storedFrameCount == 0 ? "No screen writes yet" : "Screen memory saved"
    }

    public func detailText(now: Date = Date()) -> String? {
        guard let reason = blockedReason ?? suppressionReason else { return nil }
        let detail = Self.reasonDetail(reason)
        return isStale(now: now) ? "Last report: \(detail)" : detail
    }

    // Keep receipt codes content-free, including values from a newer agent.
    private static func reasonDetail(_ code: String) -> String {
        switch code {
        case "app_denied", "denylist-source":
            return "The source is excluded by a privacy rule."
        case "denylist-postcapture":
            return "Privacy exclusions changed during capture."
        case "os-blacked-region":
            return "macOS protected this screen content."
        case "secure_input", "secure-event-input":
            return "Secure keyboard input is active."
        case "ax-secure-subrole":
            return "A password field is focused."
        case "ocr-time-secret":
            return "Sensitive text was detected before saving."
        case "failsafe-unknown":
            return "The window could not be verified as safe to capture."
        case "focus-race-dropped":
            return "The focused window changed during capture."
        case "private_browsing":
            return "Private browsing is excluded from capture."
        case "browser_window_unknown":
            return "The browser window's privacy mode could not be verified."
        case "app_identity_unknown":
            return "The current app could not be identified."
        case "screen_recording_permission":
            return "Screen Recording permission is required."
        case "accessibility_permission":
            return "Accessibility permission is required to check screen content safely."
        case "store_unavailable":
            return "Saved memory is unavailable."
        case "storage_error", "ingest_failed":
            return "The captured screen could not be saved."
        case "helper_disconnected":
            return "The screen capture helper disconnected."
        case "capture_failed":
            return "Screen capture failed."
        case "capture_disabled":
            return "Screen capture is turned off."
        case "unchanged_screen", "deduplicated":
            return "No new screen content was saved."
        default:
            return "The capture service reported an unrecognized reason."
        }
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
