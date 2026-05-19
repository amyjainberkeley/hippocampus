// SPDX-License-Identifier: TBD-private
//
// DenylistTOMLLoader — parse the user's denylist from a small TOML
// document into [`DenylistEntry`] values.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. The denylist is the
// load-bearing privacy primitive (ADR-0012 §9; AGENT_PROTOCOL §4 / R5).
// Anything that lets a hostile or malformed TOML smuggle a non-denylist
// pattern through breaks the privacy contract.
//
// Why hand-rolled TOML, not a third-party crate? The denylist schema
// is intentionally tiny (three keys per entry, three kinds), the
// helper has no other TOML use case, and pulling in `TOMLDecoder` or
// `swift-toml` adds an audit-surface for a one-file config. The
// parser below accepts a deliberately strict subset of TOML so the
// surface stays small. Anything fancier requires a CSO ADR amendment.
//
// Subset grammar (formal):
//
//     document       = (entry-table | comment | blank)*
//     entry-table    = "[[denylist]]" newline
//                       (kv-line | comment | blank){1,}
//     kv-line        = "kind" "=" quoted-string newline
//                    | "pattern" "=" quoted-string newline
//     quoted-string  = "\"" [^"\\\n]* "\""
//     comment        = "#" .* newline
//     blank          = newline
//
// No nested tables. No arrays. No multi-line strings. No escaped quotes.
// Hostile or just-malformed input returns a [`DenylistTOMLError`] —
// never a partial parse, never a `precondition` panic.

import Foundation

/// Errors `DenylistTOMLLoader` can surface.
public enum DenylistTOMLError: Error, Equatable {
    /// A `[[denylist]]` table started but no `kind=` was seen before
    /// the next table header or EOF.
    case missingKind(line: Int)
    /// A `[[denylist]]` table started but no `pattern=` was seen before
    /// the next table header or EOF.
    case missingPattern(line: Int)
    /// A `kind = "…"` value was not one of `appBundle`, `urlPrefix`,
    /// `windowTitleSubstring`.
    case unknownKind(line: Int, value: String)
    /// A `pattern = ""` (empty) — disallowed because an empty pattern
    /// would silently match nothing (or, worse, everything, depending on
    /// the matcher). Refuse rather than risk surprise.
    case emptyPattern(line: Int)
    /// A key=value line did not parse as `key = "..."`.
    case malformedKvLine(line: Int)
    /// A line outside any `[[denylist]]` table was not a comment, a
    /// blank, or the `[[denylist]]` header itself.
    case unexpectedLine(line: Int)
    /// A duplicate key inside one `[[denylist]]` table (`kind=` or
    /// `pattern=` set twice).
    case duplicateKey(line: Int, key: String)
}

/// Loader for the helper's denylist file.
///
/// `Sendable` because it's stateless — every call to `parse` is fresh.
public struct DenylistTOMLLoader: Sendable {
    public init() {}

    /// Parse a TOML string into a vector of [`DenylistEntry`] values.
    ///
    /// On success returns the parsed entries in document order. On any
    /// failure returns a [`DenylistTOMLError`] with a 1-based line
    /// number for the user-visible config-error UI Phase-1 cycle 3+
    /// will surface.
    public func parse(_ source: String) throws -> [DenylistEntry] {
        var entries: [DenylistEntry] = []
        var pendingKind: String?
        var pendingPattern: String?
        var pendingStartLine = 0
        var inTable = false

        func flushPending() throws {
            guard inTable else { return }
            guard let kind = pendingKind else {
                throw DenylistTOMLError.missingKind(line: pendingStartLine)
            }
            guard let pattern = pendingPattern else {
                throw DenylistTOMLError.missingPattern(line: pendingStartLine)
            }
            entries.append(DenylistEntry(kind: try kindFor(kind, line: pendingStartLine),
                                         pattern: pattern))
            pendingKind = nil
            pendingPattern = nil
        }

        for (idx, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = idx + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Comments + blanks pass through.
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            if line == "[[denylist]]" {
                try flushPending()
                inTable = true
                pendingStartLine = lineNumber
                continue
            }

            // Anything OUTSIDE a `[[denylist]]` table that isn't a
            // comment / blank / table-header is malformed. Refuse —
            // this is the trust-boundary semantics.
            guard inTable else {
                throw DenylistTOMLError.unexpectedLine(line: lineNumber)
            }

            let (key, value) = try parseKV(line: line, lineNumber: lineNumber)

            switch key {
            case "kind":
                if pendingKind != nil {
                    throw DenylistTOMLError.duplicateKey(line: lineNumber, key: "kind")
                }
                pendingKind = value
            case "pattern":
                if pendingPattern != nil {
                    throw DenylistTOMLError.duplicateKey(line: lineNumber, key: "pattern")
                }
                if value.isEmpty {
                    throw DenylistTOMLError.emptyPattern(line: lineNumber)
                }
                pendingPattern = value
            default:
                // Unknown key inside the table — refuse rather than
                // silently ignore. Future denylist entries might add a
                // new key, at which point this loader gets bumped + a
                // V0003-style migration story is owed.
                throw DenylistTOMLError.malformedKvLine(line: lineNumber)
            }
        }

        try flushPending()
        return entries
    }

    /// Parse `key = "value"` from a single trimmed line.
    private func parseKV(line: String, lineNumber: Int) throws -> (key: String, value: String) {
        guard let eqIdx = line.firstIndex(of: "=") else {
            throw DenylistTOMLError.malformedKvLine(line: lineNumber)
        }
        let keyPart = line[line.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
        let valuePart = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)

        // The value MUST be a quoted string: starts + ends with `"`,
        // contains no inner `"` or `\` (no escapes supported in the
        // subset).
        guard valuePart.count >= 2,
              valuePart.first == "\"",
              valuePart.last == "\"" else {
            throw DenylistTOMLError.malformedKvLine(line: lineNumber)
        }
        let inner = valuePart.dropFirst().dropLast()
        if inner.contains("\"") || inner.contains("\\") {
            throw DenylistTOMLError.malformedKvLine(line: lineNumber)
        }
        return (keyPart, String(inner))
    }

    private func kindFor(_ raw: String, line: Int) throws -> DenylistPatternKind {
        switch raw {
        case "appBundle": return .appBundle
        case "urlPrefix": return .urlPrefix
        case "windowTitleSubstring": return .windowTitleSubstring
        default: throw DenylistTOMLError.unknownKind(line: line, value: raw)
        }
    }
}
