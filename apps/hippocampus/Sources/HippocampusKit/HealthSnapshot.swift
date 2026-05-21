// SPDX-License-Identifier: TBD-private
import Foundation

public struct HealthSnapshot: Sendable, Equatable {
    public let framesDelivered: Int
    public let framesSuppressed: Int
    public let brainEventCount: Int?
    public let lastCaptureTs: Date?
    public let lastUpdated: Date

    public init(
        framesDelivered: Int,
        framesSuppressed: Int,
        brainEventCount: Int?,
        lastCaptureTs: Date?,
        lastUpdated: Date
    ) {
        self.framesDelivered = framesDelivered
        self.framesSuppressed = framesSuppressed
        self.brainEventCount = brainEventCount
        self.lastCaptureTs = lastCaptureTs
        self.lastUpdated = lastUpdated
    }

    public var eventCount: Int {
        brainEventCount ?? framesDelivered
    }

    public var displayText: String {
        let count = eventCount
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        if let ts = lastCaptureTs {
            let ago = formatter.localizedString(for: ts, relativeTo: Date())
            return "\(count) events captured · last \(ago)"
        }
        let ago = formatter.localizedString(for: lastUpdated, relativeTo: Date())
        return "\(count) events captured · \(ago)"
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
            brainEventCount: nil,
            lastCaptureTs: date,
            lastUpdated: date
        )
    }

    // MARK: - Brain stats (subprocess)

    public static func readBrainStats(
        brainPath: URL?,
        keyHex: String?,
        timeout: TimeInterval = 2.0
    ) -> Int? {
        guard let brainPath, let keyHex else { return nil }

        let process = Process()
        process.executableURL = brainPath
        process.arguments = ["stats", "--json"]
        var env = ProcessInfo.processInfo.environment
        env["MCI_DB_KEY_HEX"] = keyHex
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = json["event_count"] as? Int
        else { return nil }

        return count
    }

    public func withBrainEventCount(_ count: Int?) -> HealthSnapshot {
        HealthSnapshot(
            framesDelivered: framesDelivered,
            framesSuppressed: framesSuppressed,
            brainEventCount: count,
            lastCaptureTs: lastCaptureTs,
            lastUpdated: lastUpdated
        )
    }
}
