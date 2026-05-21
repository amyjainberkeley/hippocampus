// SPDX-License-Identifier: TBD-private
//
// AllowlistTOMLLoader — parse the CSO-ratified known-safe-apps allowlist
// from a small TOML document into `AllowlistEntry` values.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. The allowlist is the SECOND
// load-bearing privacy primitive (ADR-0013 §3 + §6; ADR-0015 §5;
// ADR-0017 §3.1). It is the per-bundle CSO trust gate that turns the
// cascade's §7 fail-closed default into a `.allow` for explicitly
// ratified app surfaces. Each entry is a deliberate trust decision —
// the loader's job is to refuse anything that smells like a smuggled
// or malformed entry rather than risk widening that gate.
//
// Why hand-rolled TOML, not a third-party crate? Same reasoning as
// `DenylistTOMLLoader.swift`: the schema is tiny (four required keys
// per entry), the helper has no other TOML use case, and pulling in a
// third-party parser inflates the audit surface for a one-file config.
// The parser below accepts a deliberately strict subset of TOML; any
// fancier surface requires a CSO ADR amendment.
//
// Subset grammar (formal):
//
//     document       = (entry-table | comment | blank)*
//     entry-table    = "[[entries]]" newline
//                       (kv-line | comment | blank){4,}
//     kv-line        = "bundle_id"       "=" quoted-string newline
//                    | "rationale"       "=" quoted-string newline
//                    | "cso_ratified_by" "=" quoted-string newline
//                    | "ratified_at"     "=" quoted-string newline
//     quoted-string  = "\"" [^"\\\n]* "\""
//     comment        = "#" .* newline
//     blank          = newline
//
// All four keys are required per entry. No nested tables. No arrays.
// No multi-line strings. No escaped quotes. Hostile or malformed input
// returns an [`AllowlistTOMLError`] — never a partial parse, never a
// `precondition` panic.
//
// CSO-protected invariants (ADR-0017 §3.1):
//   1. Empty allowlist ⇒ cascade behavior unchanged (every app falls
//      to §7 fail-closed). The loader returns `[]` for an empty
//      document; the cascade's `knownSafeAppBundles` Set stays empty.
//   2. The loader STRICTLY ADDS to `knownSafeAppBundles`. It cannot
//      widen `.allow` past the §2-§7 cascade order — any §3/§4
//      redaction signal still wins. (This invariant lives in
//      `SuppressionCascade.decide(context:)`, not here, but is the
//      reason the loader can safely emit a `Set<String>` of bundle
//      ids without further policy attached.)

import Foundation

/// A single allowlist entry — one CSO-ratified app surface.
///
/// Every field is REQUIRED. The loader refuses any `[[entries]]` table
/// missing any of the four. The non-`bundleId` fields exist for human
/// auditability of the trust decision; the cascade only consumes
/// `bundleId`. `rationale` is the CSO's stated reason; `csoRatifiedBy`
/// records the ratifier identity; `ratifiedAt` is the ISO-8601-style
/// date the entry was added. ADR-0017 §3.1 v2+ will surface this in
/// the recall-UI's "What MCI Sees" panel; v1 keeps it loader-internal.
public struct AllowlistEntry: Sendable, Equatable {
    /// CFBundleIdentifier of the ratified app. Used by the cascade.
    public let bundleId: String
    /// Why the CSO considers this surface safe. Human-readable; not
    /// machine-consumed by the cascade.
    public let rationale: String
    /// Identity (role-mask) of the CSO/orchestrator-seat that ratified.
    public let csoRatifiedBy: String
    /// ISO-8601 date (yyyy-mm-dd) the entry was ratified.
    public let ratifiedAt: String

    public init(
        bundleId: String,
        rationale: String,
        csoRatifiedBy: String,
        ratifiedAt: String
    ) {
        self.bundleId = bundleId
        self.rationale = rationale
        self.csoRatifiedBy = csoRatifiedBy
        self.ratifiedAt = ratifiedAt
    }
}

/// Errors `AllowlistTOMLLoader` can surface. Each carries a 1-based
/// line number so a user-visible config-error UI (Phase-4) can point
/// at the offending source line. `Equatable` so test assertions can
/// pin exact failure modes.
public enum AllowlistTOMLError: Error, Equatable {
    /// An `[[entries]]` table started but no `bundle_id=` was seen
    /// before the next table header or EOF.
    case missingBundleId(line: Int)
    /// An `[[entries]]` table started but no `rationale=` was seen
    /// before the next table header or EOF.
    case missingRationale(line: Int)
    /// An `[[entries]]` table started but no `cso_ratified_by=` was
    /// seen before the next table header or EOF.
    case missingCsoRatifiedBy(line: Int)
    /// An `[[entries]]` table started but no `ratified_at=` was seen
    /// before the next table header or EOF.
    case missingRatifiedAt(line: Int)
    /// A `<key> = ""` (empty) — disallowed because an empty bundle
    /// would silently match nothing (or, worse in audit contexts,
    /// could be interpreted as a wildcard). Refuse rather than risk
    /// surprise. `key` names which field was empty.
    case emptyValue(line: Int, key: String)
    /// A key=value line did not parse as `key = "..."`.
    case malformedKvLine(line: Int)
    /// A line outside any `[[entries]]` table was not a comment, a
    /// blank, or the `[[entries]]` header itself.
    case unexpectedLine(line: Int)
    /// A duplicate key inside one `[[entries]]` table.
    case duplicateKey(line: Int, key: String)
}

/// In-memory snapshot of the CSO-ratified allowlist.
///
/// Constructed from `[AllowlistEntry]` values (parsed by
/// `AllowlistTOMLLoader`). `Sendable` because the underlying state is
/// an immutable `Set<String>`; matching is read-only and lock-free.
///
/// The helper holds one `Allowlist` for its process lifetime; signed
///-update bundles (Phase 5) rebuild it. The cascade reads the bundle
/// id `Set` via `bundleIdSet` and feeds it to `SuppressionCascade`'s
/// `knownSafeAppBundles` field — see `main.swift`.
public struct Allowlist: Sendable, Equatable {
    /// All ratified bundle ids, deduped.
    private let bundleIds: Set<String>
    /// Original entries in document order (for the "What MCI Sees"
    /// read-only panel Phase 4.3 surfaces).
    public let entries: [AllowlistEntry]

    public init(entries: [AllowlistEntry]) {
        self.entries = entries
        var ids: Set<String> = []
        for e in entries { ids.insert(e.bundleId) }
        self.bundleIds = ids
    }

    /// True iff `bundleId` is in the ratified set.
    public func contains(_ bundleId: String) -> Bool {
        bundleIds.contains(bundleId)
    }

    /// Bundle-id `Set` consumed by `SuppressionCascade`'s
    /// `knownSafeAppBundles`. Same shape as the existing
    /// cascade-constructor parameter so wiring is a one-liner.
    public var bundleIdSet: Set<String> {
        bundleIds
    }
}

/// Loader for the helper's known-safe-apps allowlist file.
///
/// `Sendable` because it's stateless — every call to `parse` is fresh.
public struct AllowlistTOMLLoader: Sendable {
    public init() {}

    /// Parse a TOML string into a vector of `AllowlistEntry` values.
    ///
    /// On success returns the parsed entries in document order. On any
    /// failure returns an `AllowlistTOMLError` with a 1-based line
    /// number. CSO-ratified config files MUST round-trip cleanly; any
    /// error indicates either a hand-edit (which the loader refuses by
    /// design — see ADR-0017 §3.1) or a damaged bundle resource.
    public func parse(_ source: String) throws -> [AllowlistEntry] {
        var entries: [AllowlistEntry] = []
        var pendingBundleId: String?
        var pendingRationale: String?
        var pendingCsoRatifiedBy: String?
        var pendingRatifiedAt: String?
        var pendingStartLine = 0
        var inTable = false

        func flushPending() throws {
            guard inTable else { return }
            guard let bundleId = pendingBundleId else {
                throw AllowlistTOMLError.missingBundleId(line: pendingStartLine)
            }
            guard let rationale = pendingRationale else {
                throw AllowlistTOMLError.missingRationale(line: pendingStartLine)
            }
            guard let csoRatifiedBy = pendingCsoRatifiedBy else {
                throw AllowlistTOMLError.missingCsoRatifiedBy(line: pendingStartLine)
            }
            guard let ratifiedAt = pendingRatifiedAt else {
                throw AllowlistTOMLError.missingRatifiedAt(line: pendingStartLine)
            }
            entries.append(AllowlistEntry(
                bundleId: bundleId,
                rationale: rationale,
                csoRatifiedBy: csoRatifiedBy,
                ratifiedAt: ratifiedAt
            ))
            pendingBundleId = nil
            pendingRationale = nil
            pendingCsoRatifiedBy = nil
            pendingRatifiedAt = nil
        }

        for (idx, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = idx + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Comments + blanks pass through.
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            if line == "[[entries]]" {
                try flushPending()
                inTable = true
                pendingStartLine = lineNumber
                continue
            }

            // Anything OUTSIDE an `[[entries]]` table that isn't a
            // comment / blank / table-header is malformed. Refuse —
            // this is the trust-boundary semantics.
            guard inTable else {
                throw AllowlistTOMLError.unexpectedLine(line: lineNumber)
            }

            let (key, value) = try parseKV(line: line, lineNumber: lineNumber)

            switch key {
            case "bundle_id":
                if pendingBundleId != nil {
                    throw AllowlistTOMLError.duplicateKey(line: lineNumber, key: "bundle_id")
                }
                if value.isEmpty {
                    throw AllowlistTOMLError.emptyValue(line: lineNumber, key: "bundle_id")
                }
                pendingBundleId = value
            case "rationale":
                if pendingRationale != nil {
                    throw AllowlistTOMLError.duplicateKey(line: lineNumber, key: "rationale")
                }
                if value.isEmpty {
                    throw AllowlistTOMLError.emptyValue(line: lineNumber, key: "rationale")
                }
                pendingRationale = value
            case "cso_ratified_by":
                if pendingCsoRatifiedBy != nil {
                    throw AllowlistTOMLError.duplicateKey(line: lineNumber, key: "cso_ratified_by")
                }
                if value.isEmpty {
                    throw AllowlistTOMLError.emptyValue(line: lineNumber, key: "cso_ratified_by")
                }
                pendingCsoRatifiedBy = value
            case "ratified_at":
                if pendingRatifiedAt != nil {
                    throw AllowlistTOMLError.duplicateKey(line: lineNumber, key: "ratified_at")
                }
                if value.isEmpty {
                    throw AllowlistTOMLError.emptyValue(line: lineNumber, key: "ratified_at")
                }
                pendingRatifiedAt = value
            default:
                // Unknown key inside the table — refuse rather than
                // silently ignore. Allowlist schema is locked; widening
                // requires a fresh ADR.
                throw AllowlistTOMLError.malformedKvLine(line: lineNumber)
            }
        }

        try flushPending()
        return entries
    }

    /// Parse `key = "value"` from a single trimmed line.
    private func parseKV(line: String, lineNumber: Int) throws -> (key: String, value: String) {
        guard let eqIdx = line.firstIndex(of: "=") else {
            throw AllowlistTOMLError.malformedKvLine(line: lineNumber)
        }
        let keyPart = line[line.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
        let valuePart = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)

        // The value MUST be a quoted string: starts + ends with `"`,
        // contains no inner `"` or `\` (no escapes supported in the
        // subset).
        guard valuePart.count >= 2,
              valuePart.first == "\"",
              valuePart.last == "\"" else {
            throw AllowlistTOMLError.malformedKvLine(line: lineNumber)
        }
        let inner = valuePart.dropFirst().dropLast()
        if inner.contains("\"") || inner.contains("\\") {
            throw AllowlistTOMLError.malformedKvLine(line: lineNumber)
        }
        return (keyPart, String(inner))
    }
}

extension AllowlistTOMLLoader {
    /// Bundled-resource name (no extension) the helper loads at startup.
    /// The file lives under `Sources/MCICaptureHelperKit/Resources/` and
    /// is bundled into the SwiftPM target via `.copy(...)` in
    /// `Package.swift`.
    public static let bundledResourceName = "known-safe-apps"

    /// Loaded from the signed module bundle (`Bundle.module`). Returns
    /// an empty `Allowlist` if the resource is absent — the cascade's
    /// §7 fail-closed default keeps the privacy invariant intact when
    /// the seed file is missing (e.g. some test contexts). Throws
    /// `AllowlistTOMLError` if the resource is present but malformed —
    /// CSO-ratified config files MUST round-trip cleanly, and a parse
    /// failure here points at either a damaged bundle or a hand-edit
    /// the loader refuses by design (ADR-0017 §3.1).
    public static func loadBundled() throws -> Allowlist {
        guard let url = Bundle.module.url(
            forResource: bundledResourceName,
            withExtension: "toml"
        ) else {
            return Allowlist(entries: [])
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let entries = try AllowlistTOMLLoader().parse(source)
        return Allowlist(entries: entries)
    }
}
