// SPDX-License-Identifier: TBD-private
import Foundation

public struct HealthSnapshot: Sendable, Equatable {
    public let framesDelivered: Int
    public let framesSuppressed: Int
    public let lastCaptureTs: Date?
    public let lastUpdated: Date

    public init(
        framesDelivered: Int,
        framesSuppressed: Int,
        lastCaptureTs: Date?,
        lastUpdated: Date
    ) {
        self.framesDelivered = framesDelivered
        self.framesSuppressed = framesSuppressed
        self.lastCaptureTs = lastCaptureTs
        self.lastUpdated = lastUpdated
    }

    public var displayText: String {
        "Helper: \(framesDelivered) delivered · \(framesSuppressed) suppressed (not saved counts)"
    }

    // MARK: - Health log parsing

    public static func readFromLog() -> HealthSnapshot? {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MCI/helper-health.jsonl")
        return readFromLog(at: logPath)
    }

    public static func readFromLog(at path: URL) -> HealthSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        // Read a bounded tail even after the helper has run for days.
        guard let size = try? handle.seekToEnd() else { return nil }
        do { try handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0) }
        catch { return nil }
        guard let data = try? handle.readToEnd(),
              let lastLine = String(data: data, encoding: .utf8)?
                .split(separator: "\n")
                .last,
              let json = try? JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any]
        else { return nil }

        let framesDelivered = (json["frames_delivered"] as? Int) ?? 0
        let framesSuppressed = (json["frames_suppressed"] as? Int) ?? 0
        let wallTs = (json["wall_ts"] as? String) ?? ""

        guard let date = CaptureStatusReceipt.parseTimestamp(wallTs),
              framesDelivered >= 0, framesSuppressed >= 0 else { return nil }

        return HealthSnapshot(
            framesDelivered: framesDelivered,
            framesSuppressed: framesSuppressed,
            lastCaptureTs: nil,
            lastUpdated: date
        )
    }
}
