// SPDX-License-Identifier: TBD-private
//
// McpServersTOMLDocument — parse + emit the V2-MCP-2 schema in
// OnboardingKit. Mirrors the strict subset implemented by
// `core/mcp-client/src/config.rs` so the two sides stay in lockstep:
// every emit MUST round-trip cleanly through both parsers.
//
// Schema (binding, schema version 1):
//
//     # Schema version 1. Edited via Hippocampus onboarding; manual
//     # edits supported but uid + mode must match.
//     [[server]]
//     name = "gchat"
//     url = "http://127.0.0.1:7890/mcp"
//     auth_header = "Bearer sk-..."   # optional
//     enabled = true                  # optional, default true
//
// The OnboardingKit-side reader is forgiving by design (unknown keys
// are skipped rather than errored) because the agent's `McpServersConfig`
// loader is the source of truth for "is this file malformed"; this
// reader only needs to recover the user's previously persisted choices.

import Foundation

public enum McpServersTOMLDocument {
    public static func emit(_ entries: [McpServerEntry]) -> String {
        var lines: [String] = [
            "# MCI mcp-servers v1",
            "# User-registered MCP servers per ADR-0001 amendment 2026-05-31.",
            "# Loopback-only — http://127.0.0.1, http://[::1], or http://localhost.",
            "# The agent reads this file on start and connects one HTTP+SSE",
            "# transport per [[server]] with enabled = true. Re-launch the",
            "# agent to pick up edits.",
            "",
        ]
        for entry in entries {
            lines.append("[[server]]")
            lines.append("name = \(quoted(entry.name))")
            lines.append("url = \(quoted(entry.url))")
            if let auth = entry.authHeader, !auth.isEmpty {
                lines.append("auth_header = \(quoted(auth))")
            }
            // Always emit `enabled` so a future re-read with a default
            // change does not silently flip user-intended state.
            lines.append("enabled = \(entry.enabled ? "true" : "false")")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func parse(_ source: String) throws -> [McpServerEntry] {
        var entries: [McpServerEntry] = []
        var pendingName: String?
        var pendingURL: String?
        var pendingAuth: String?
        var pendingEnabled: Bool?
        var inTable = false

        func flushPending() {
            guard inTable else { return }
            defer {
                pendingName = nil
                pendingURL = nil
                pendingAuth = nil
                pendingEnabled = nil
            }
            guard let name = pendingName,
                  let url = pendingURL else {
                return
            }
            entries.append(McpServerEntry(
                name: name,
                url: url,
                authHeader: pendingAuth,
                enabled: pendingEnabled ?? true
            ))
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "[[server]]" {
                flushPending()
                inTable = true
                continue
            }
            guard inTable else { continue }
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "name":
                pendingName = unquoted(value)
            case "url":
                pendingURL = unquoted(value)
            case "auth_header":
                pendingAuth = unquoted(value)
            case "enabled":
                pendingEnabled = (value == "true")
            default:
                continue
            }
        }
        flushPending()
        return entries
    }

    private static func quoted(_ s: String) -> String {
        // Strip `"` and `\` defensively. The agent-side loader's
        // toml-rs parser handles escaping properly, but emitting a
        // strict subset keeps the file safely round-trippable through
        // both parsers and avoids hostile-input edge cases.
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
