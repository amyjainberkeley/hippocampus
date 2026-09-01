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
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        if let ts = lastCaptureTs {
            let ago = formatter.localizedString(for: ts, relativeTo: Date())
            return "\(framesDelivered) frames processed · last \(ago)"
        }
        let ago = formatter.localizedString(for: lastUpdated, relativeTo: Date())
        return "\(framesDelivered) frames processed · \(ago)"
    }

    // MARK: - Health log parsing

    public static func readFromLog() -> HealthSnapshot? {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MCI/helper-health.jsonl")
        return readFromLog(at: logPath)
    }

    public static func readFromLog(at path: URL) -> HealthSnapshot? {
        guard let data = try? Data(contentsOf: path),
              let lastLine = String(data: data, encoding: .utf8)?
                .split(separator: "\n")
                .last,
              let json = try? JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any]
        else { return nil }

        let framesDelivered = (json["frames_delivered"] as? Int) ?? 0
        let framesSuppressed = (json["frames_suppressed"] as? Int) ?? 0
        let wallTs = (json["wall_ts"] as? String) ?? ""

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fmt.date(from: wallTs) ?? Date()

        return HealthSnapshot(
            framesDelivered: framesDelivered,
            framesSuppressed: framesSuppressed,
            lastCaptureTs: date,
            lastUpdated: date
        )
    }
}
