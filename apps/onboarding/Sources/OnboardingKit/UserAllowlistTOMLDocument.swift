// SPDX-License-Identifier: TBD-private
//
// UserAllowlistTOMLDocument — parse + emit the user-allowlist TOML
// schema in OnboardingKit. Mirrors the strict subset implemented by
// `UserAllowlistTOMLLoader` in MCICaptureHelperKit so the two sides
// stay in lockstep — every emit MUST round-trip cleanly through both
// parsers. The OnboardingKit-side reader is forgiving by design
// (unknown keys are skipped rather than errored) because the helper
// is the source of truth for "is this a malformed file"; OnboardingKit
// only needs to recover the user's previously persisted choices.
//
// Schema (binding):
//
//     [[entries]]
//     bundle_id = "com.spotify.client"
//     capture_enabled = true
//     deep_hook_enabled = false
//     added_at = "2026-05-29"
//     rationale = "Music app"   # optional

import Foundation

public enum UserAllowlistTOMLDocument {
    public static func emit(_ entries: [UserAllowlistEntry]) -> String {
        var lines: [String] = [
            "# MCI user-allowlist v1",
            "# User-curated allowlist layer per ADR-0017 §3.2 (V2-P10).",
            "# Each entry is a user opt-in; the capture-side cascade unions",
            "# this set with the CSO baseline (known-safe-apps.toml). All",
            "# entries flow through the SAME §2–§7 cascade arms + cascade-",
            "# twice OCR redaction as the baseline — user-layer cannot",
            "# widen `.allow` past any redaction signal.",
            "",
        ]
        for entry in entries {
            lines.append("[[entries]]")
            lines.append("bundle_id = \(quoted(entry.bundleId))")
            lines.append("capture_enabled = \(entry.captureEnabled ? "true" : "false")")
            lines.append("deep_hook_enabled = \(entry.deepHookEnabled ? "true" : "false")")
            lines.append("added_at = \(quoted(entry.addedAt))")
            if let rationale = entry.rationale, !rationale.isEmpty {
                lines.append("rationale = \(quoted(rationale))")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func parse(_ source: String) throws -> [UserAllowlistEntry] {
        var entries: [UserAllowlistEntry] = []
        var pendingBundleId: String?
        var pendingCapture: Bool?
        var pendingDeepHook: Bool?
        var pendingAddedAt: String?
        var pendingRationale: String?
        var inTable = false

        func flushPending() {
            guard inTable else { return }
            guard let bundleId = pendingBundleId,
                  let capture = pendingCapture,
                  let deepHook = pendingDeepHook,
                  let addedAt = pendingAddedAt else {
                // OnboardingKit reader: tolerate incomplete entries
                // (helper's strict reader is the source of truth for
                // schema enforcement). Drop incomplete rows silently.
                pendingBundleId = nil
                pendingCapture = nil
                pendingDeepHook = nil
                pendingAddedAt = nil
                pendingRationale = nil
                return
            }
            entries.append(UserAllowlistEntry(
                bundleId: bundleId,
                captureEnabled: capture,
                deepHookEnabled: deepHook,
                addedAt: addedAt,
                rationale: pendingRationale
            ))
            pendingBundleId = nil
            pendingCapture = nil
            pendingDeepHook = nil
            pendingAddedAt = nil
            pendingRationale = nil
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "[[entries]]" {
                flushPending()
                inTable = true
                continue
            }
            guard inTable else { continue }
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "bundle_id":
                pendingBundleId = unquoted(value)
            case "capture_enabled":
                pendingCapture = (value == "true")
            case "deep_hook_enabled":
                pendingDeepHook = (value == "true")
            case "added_at":
                pendingAddedAt = unquoted(value)
            case "rationale":
                pendingRationale = unquoted(value)
            default:
                continue
            }
        }
        flushPending()
        return entries
    }

    private static func quoted(_ s: String) -> String {
        // Bundle ids and dates do not contain `"` or `\` in practice;
        // the helper's reader refuses anything that does. Sanitize on
        // emit so a hostile rationale string (user-typed) cannot break
        // the file out of the strict subset.
        let safe = s
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\"", with: "")
        return "\"\(safe)\""
    }

    private static func unquoted(_ value: String) -> String? {
        guard value.count >= 2,
              value.first == "\"",
              value.last == "\"" else { return nil }
        return String(value.dropFirst().dropLast())
    }
}
