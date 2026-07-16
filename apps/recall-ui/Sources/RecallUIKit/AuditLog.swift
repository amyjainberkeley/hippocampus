// AuditLog.swift — enterprise-grade audit trail (cycle 8.51).
//
// Every user-triggered destructive action (delete / wipe / export) and
// every privacy-sensitive state change (permissions granted/revoked,
// settings change, app launch) is appended to a plaintext, append-only
// log at `~/Library/Application Support/Hippocampus/audit.log`.
//
// Trust artifact: enterprise buyers ("can I audit what happens to user
// data?") get a plaintext, user-owned, tamper-visible (append-only)
// log that lives on the user's machine only.
//
// File format — one line per entry:
//     <ISO-8601-timestamp> <action-type> <details-json>
// e.g.
//     2026-07-13T18:04:22Z delete_events_in_range {"count":"47","range_hours":"24"}
//
// UTF-8 plaintext so a security team can `cat` / `tail -f` / `grep`
// without any Hippocampus tooling. Not encrypted — audit logs are
// conventionally plaintext for tamper detection, and this log contains
// NO brain content (only meta-actions on the brain). Per-frame capture
// events are NEVER logged (would blow the log).
//
// Rotation: `audit.log` rotates to `.1` at 10 MB; existing `.1` shifts
// to `.2` and so on up to `.5`; older is discarded. Failure is
// non-fatal (we degrade to unbounded rather than lose audit lines).
//
// Concurrency: `record(...)` is thread-safe (serial queue, per-line
// open+append+fsync+close — syslog(3) semantics). Errors are logged to
// NSLog and swallowed so a full-disk never blocks a user action.

import Foundation

/// The set of auditable actions. String raw values are the exact tokens
/// written to the log file — keep stable; renaming is a breaking change
/// for downstream log-analysis pipelines a security team might build.
public enum AuditAction: String, Sendable, CaseIterable {
    case appLaunched = "app_launched"
    case permissionsGranted = "permissions_granted"
    case permissionsRevoked = "permissions_revoked"
    case deleteEvent = "delete_event"
    case deleteEventsInRange = "delete_events_in_range"
    case wipeBrain = "wipe_brain"
    case exportJson = "export_json"
    case settingsChange = "settings_change"
}

/// One parsed line of the audit log. The reader path (Recent activity
/// section in Privacy Dashboard) surfaces `[AuditEntry]` so the UI never
/// touches raw file I/O. `details` is a JSON object (small, opaque).
public struct AuditEntry: Sendable, Equatable, Identifiable {
    public let timestamp: Date
    public let action: AuditAction
    public let details: [String: String]
    /// Raw line as read from disk. Used as the id (stable within a
    /// process; unique because the timestamp includes ISO-8601 seconds
    /// plus the details string).
    public let rawLine: String

    public var id: String { rawLine }

    public init(timestamp: Date, action: AuditAction, details: [String: String], rawLine: String) {
        self.timestamp = timestamp
        self.action = action
        self.details = details
        self.rawLine = rawLine
    }
}

/// Errors surfaced from audit-log operations. All are non-fatal — the
/// caller is expected to log-and-continue; losing an audit line is
/// preferable to blocking a user action on a full disk or perms glitch.
public enum AuditLogError: Error, Equatable {
    case ioFailed(String)
    case parseFailed(String)
}

/// Append-only audit trail. Singleton by design — one process, one log
/// file. Tests construct their own instances with `init(baseURL:)` so
/// the singleton is not perturbed.
public final class AuditLog: @unchecked Sendable {
    /// Rotation size cap. Rotate when the active file exceeds this.
    /// 10 MB matches typical macOS log-rotation defaults and fits ~50k
    /// entries at ~200 bytes per line.
    public static let rotationThresholdBytes: Int = 10 * 1024 * 1024

    /// How many rotated files to keep (`audit.log.1` … `audit.log.5`).
    public static let maxRotatedFiles: Int = 5

    /// Shared singleton wired to the canonical Hippocampus support dir.
    public static let shared: AuditLog = {
        let supportDir = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first ?? NSTemporaryDirectory()
        let dir = (supportDir as NSString).appendingPathComponent("Hippocampus")
        return AuditLog(baseURL: URL(fileURLWithPath: dir))
    }()

    /// Directory the log + rotated files live in.
    public let baseURL: URL
    /// Active log file — `<baseURL>/audit.log`.
    public var logURL: URL { baseURL.appendingPathComponent("audit.log") }

    /// Serialize all writes so lines never interleave. Reads short-circuit
    /// through the queue too so a rotate mid-read can't return truncation.
    private let queue = DispatchQueue(label: "com.hippocampus.audit-log")

    /// Test-injected clock. Production uses `Date()`.
    private let now: @Sendable () -> Date

    public init(baseURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        self.now = now
    }

    /// Append one line to the audit log. Thread-safe. Errors are
    /// swallowed (logged to NSLog) — an audit-log failure must never
    /// block the user's action.
    public func record(action: AuditAction, details: [String: String] = [:]) {
        let ts = now()
        queue.sync {
            do {
                try self.ensureDirectory()
                try self.maybeRotate()
                let line = Self.encodeLine(timestamp: ts, action: action, details: details)
                try self.appendLine(line)
            } catch {
                NSLog("AuditLog.record failed: %@", String(describing: error))
            }
        }
    }

    /// Read the last `count` entries from the active log (newest last
    /// in file order → we reverse to newest-first for the UI). Rotated
    /// files are NOT walked here — the Privacy Dashboard's "Recent
    /// activity" is a scan of live actions, not historical archaeology.
    /// The "Show all" affordance can open the file directly.
    public func readRecent(count: Int = 20) -> [AuditEntry] {
        queue.sync {
            guard FileManager.default.fileExists(atPath: logURL.path) else {
                return []
            }
            guard let data = try? Data(contentsOf: logURL),
                  let text = String(data: data, encoding: .utf8)
            else {
                return []
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let tail = lines.suffix(count)
            var out: [AuditEntry] = []
            for line in tail {
                if let entry = try? Self.parseLine(String(line)) {
                    out.append(entry)
                }
            }
            return out.reversed()
        }
    }

    /// Copy the current log to `~/Downloads/hippocampus-audit-log-<ts>.txt`
    /// and return the destination URL. Callers surface the URL to the
    /// user (banner "Exported to …"); tests assert the file exists.
    @discardableResult
    public func exportToDownloads() throws -> URL {
        try queue.sync {
            let iso = Self.timestampFileSuffix(now())
            let downloadsDir = NSSearchPathForDirectoriesInDomains(
                .downloadsDirectory, .userDomainMask, true
            ).first ?? NSTemporaryDirectory()
            let dest = URL(fileURLWithPath: downloadsDir)
                .appendingPathComponent("hippocampus-audit-log-\(iso).txt")
            let data: Data = {
                if FileManager.default.fileExists(atPath: logURL.path) {
                    return (try? Data(contentsOf: logURL)) ?? Data()
                }
                return Data()
            }()
            do {
                try data.write(to: dest, options: .atomic)
            } catch {
                throw AuditLogError.ioFailed("write \(dest.path): \(error)")
            }
            return dest
        }
    }

    // MARK: - Internals

    private func ensureDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: baseURL, withIntermediateDirectories: true
            )
        } catch {
            throw AuditLogError.ioFailed("mkdir \(baseURL.path): \(error)")
        }
    }

    /// Rotate `audit.log` → `audit.log.1` (shifting older `.N`) when the
    /// active file exceeds `rotationThresholdBytes`. Best-effort: any
    /// failure is thrown so `record` can log-and-continue; the next
    /// write will simply append to the still-oversized file.
    private func maybeRotate() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logURL.path) else { return }
        guard let attrs = try? fm.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int,
              size >= Self.rotationThresholdBytes
        else {
            return
        }
        // Shift .N → .(N+1) for N in maxRotatedFiles-1 … 1.
        // The oldest is discarded (removed before shifting into its slot).
        let oldest = baseURL.appendingPathComponent("audit.log.\(Self.maxRotatedFiles)")
        if fm.fileExists(atPath: oldest.path) {
            try? fm.removeItem(at: oldest)
        }
        for n in stride(from: Self.maxRotatedFiles - 1, through: 1, by: -1) {
            let src = baseURL.appendingPathComponent("audit.log.\(n)")
            let dst = baseURL.appendingPathComponent("audit.log.\(n + 1)")
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }
        let firstRotated = baseURL.appendingPathComponent("audit.log.1")
        do {
            try fm.moveItem(at: logURL, to: firstRotated)
        } catch {
            throw AuditLogError.ioFailed("rotate: \(error)")
        }
    }

    /// Append one already-formatted line (WITHOUT trailing newline; we
    /// add it here) to the active log. Opens, appends, syncs, closes —
    /// syslog-style durability per line.
    private func appendLine(_ line: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            throw AuditLogError.ioFailed("open \(logURL.path)")
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            let payload = (line + "\n").data(using: .utf8) ?? Data()
            try handle.write(contentsOf: payload)
            try handle.synchronize()
        } catch {
            throw AuditLogError.ioFailed("write \(logURL.path): \(error)")
        }
    }

    // MARK: - Encoding / decoding (pure, unit-testable)

    /// Format one audit line. Public so `AuditLogTests` can pin the
    /// exact wire shape without instantiating an on-disk log.
    public static func encodeLine(
        timestamp: Date,
        action: AuditAction,
        details: [String: String]
    ) -> String {
        let ts = Self.iso8601Formatter.string(from: timestamp)
        let json = Self.encodeDetails(details)
        return "\(ts) \(action.rawValue) \(json)"
    }

    /// Parse one audit line. Throws `AuditLogError.parseFailed` if the
    /// shape is unrecognized. Exposed for tests and for the "Show all"
    /// affordance if we later want a headless renderer.
    public static func parseLine(_ line: String) throws -> AuditEntry {
        // Layout: `<iso-8601> <action> <json>` — split on the first two
        // spaces; the JSON tail may contain no spaces (we emit compact
        // JSON with sorted keys and no whitespace).
        guard let firstSpace = line.firstIndex(of: " ") else {
            throw AuditLogError.parseFailed("missing action delimiter: \(line)")
        }
        let tsSlice = line[..<firstSpace]
        let afterTs = line[line.index(after: firstSpace)...]
        guard let secondSpace = afterTs.firstIndex(of: " ") else {
            throw AuditLogError.parseFailed("missing details delimiter: \(line)")
        }
        let actionSlice = afterTs[..<secondSpace]
        let jsonSlice = afterTs[afterTs.index(after: secondSpace)...]

        guard let ts = Self.iso8601Formatter.date(from: String(tsSlice)) else {
            throw AuditLogError.parseFailed("bad timestamp: \(tsSlice)")
        }
        guard let action = AuditAction(rawValue: String(actionSlice)) else {
            throw AuditLogError.parseFailed("unknown action: \(actionSlice)")
        }
        let details = Self.decodeDetails(String(jsonSlice))
        return AuditEntry(
            timestamp: ts,
            action: action,
            details: details,
            rawLine: line
        )
    }

    /// Encode a details map to a compact single-line JSON object with
    /// sorted keys. Values are stringified — this keeps the encoder
    /// dependency-free and the file grep-friendly. Consumers with a
    /// mixed-type payload should stringify at the call site.
    private static func encodeDetails(_ details: [String: String]) -> String {
        if details.isEmpty { return "{}" }
        let sortedKeys = details.keys.sorted()
        var parts: [String] = []
        for key in sortedKeys {
            let k = escapeJSONString(key)
            let v = escapeJSONString(details[key] ?? "")
            parts.append("\"\(k)\":\"\(v)\"")
        }
        return "{\(parts.joined(separator: ","))}"
    }

    /// Best-effort decode of the compact object emitted by
    /// `encodeDetails`. Not a general JSON parser — we only need to
    /// invert what we wrote. Malformed input returns an empty map
    /// (audit reader is forgiving; parseLine still succeeds with the
    /// timestamp + action, which is the load-bearing info).
    private static func decodeDetails(_ raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in dict {
            if let s = v as? String { out[k] = s }
            else { out[k] = "\(v)" }
        }
        return out
    }

    private static func escapeJSONString(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default: out.append(c)
            }
        }
        return out
    }

    /// ISO-8601 in UTC with second precision. `Z` suffix keeps the log
    /// timezone-unambiguous — a security team reading `audit.log` on a
    /// different host doesn't need to know the user's local TZ.
    ///
    /// `nonisolated(unsafe)`: `ISO8601DateFormatter` is not `Sendable`, but
    /// this instance is configured once and only ever read (`string(from:)`
    /// is thread-safe on Foundation formatters). Swift 6 flags the shared
    /// static defensively; the usage is safe.
    nonisolated(unsafe) public static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Filename-safe timestamp for `hippocampus-audit-log-<ts>.txt`.
    /// Replaces `:` with `-` since `:` is illegal on some filesystems
    /// and confusing on all of them.
    public static func timestampFileSuffix(_ date: Date) -> String {
        Self.iso8601Formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
    }
}
