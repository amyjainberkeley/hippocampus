// SPDX-License-Identifier: TBD-private
import Foundation

public struct HealthSnapshot: Sendable, Equatable {
    public let eventCount: Int
    public let lastUpdated: Date

    public init(eventCount: Int, lastUpdated: Date) {
        self.eventCount = eventCount
        self.lastUpdated = lastUpdated
    }

    public var displayText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let ago = formatter.localizedString(for: lastUpdated, relativeTo: Date())
        return "Captured \(eventCount) events · \(ago)"
    }

    public static func readFromLog() -> HealthSnapshot? {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MCI/helper-health.jsonl")
        guard let data = try? Data(contentsOf: logPath),
              let lastLine = String(data: data, encoding: .utf8)?
                .split(separator: "\n")
                .last,
              let json = try? JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any]
        else { return nil }

        let eventCount = (json["frames_delivered"] as? Int) ?? 0
        let wallTs = (json["wall_ts"] as? String) ?? ""

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fmt.date(from: wallTs) ?? Date()

        return HealthSnapshot(eventCount: eventCount, lastUpdated: date)
    }
}
