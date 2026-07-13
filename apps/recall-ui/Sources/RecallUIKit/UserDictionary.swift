// UserDictionary.swift — user-defined entity aliases (cycle 8.42).
//
// Inspired by EnviousWispr's "custom words with confidence-aware matching"
// pattern. Lets the user teach the recall UI that "AJ" = "Amy Jain" or
// "MCI" = "Hippocampus" so searches understand their own private
// vocabulary. Real UX win + a differentiator vs Rewind (which had no
// such feature).
//
// # Storage
//
// Plain TOML at `~/Library/Application Support/Hippocampus/user_dictionary.toml`.
// User-typed content — the user's own words about their own contacts and
// topics — with **no MCI-brain content**, so no SQLCipher needed. The user
// can hand-edit the file if they want. Format:
//
//     version = 1
//
//     [[aliases]]
//     canonical = "Amy Jain"
//     aliases = ["Amy", "@amyjainberkeley", "AJ"]
//
//     [[aliases]]
//     canonical = "Hippocampus"
//     aliases = ["MCI", "the memory app"]
//
// # How it's applied
//
// At query time, `SearchViewModel` (or any recall pipeline) reads the
// dictionary and passes the alias map to the reader. The FFI expands
// the FTS5 query by ORing in the canonical + alias tokens so a search
// for "AJ email" also matches events that mention "Amy Jain email" —
// without touching the entity graph or the resolver (both protected-set).
//
// # What lives here
//
// - `UserDictionaryEntry` — one canonical name + its alias list.
// - `UserDictionary` — the collection + validation + Codable TOML
//   round-trip (a minimal hand-parser; no external crate).
// - `defaultUserDictionaryURL()` / `loadUserDictionary()` /
//   `saveUserDictionary(_:)` — disk I/O with sensible failure modes
//   (missing file = empty dictionary; malformed file = throw).
//
// # What does NOT live here
//
// - No brain FFI. The dictionary is user-typed metadata; it never touches
//   `mci-brain-ffi` directly. `SearchViewModel` composes the two.
// - No `AliasResolver` interop. The brain's entity graph clustering is
//   protected-set (ADR-0016 §4.3); user dictionary is a separate, weaker
//   OR-expansion signal applied only at the query surface.

import Foundation

/// One user-defined mapping: a canonical name and its list of aliases.
/// Both sides are user-typed strings — the recall UI treats them as
/// opaque tokens for FTS5 OR-expansion. Optional `createdAt` is a
/// convenience field for future "recently added" affordances; storage
/// tolerates its absence.
public struct UserDictionaryEntry: Sendable, Equatable, Identifiable, Codable {
    public var id: String { canonical }
    /// The primary spelling the user wants results to align to. e.g.
    /// `"Amy Jain"`. Case-preserved; the FFI treats FTS5 as
    /// case-insensitive so `"amy jain"` and `"Amy Jain"` both match.
    public let canonical: String
    /// Alternate spellings the user wants to treat as the same person /
    /// org / topic. e.g. `["AJ", "Amy", "@amyjainberkeley"]`. Order is
    /// preserved for stable file writes and stable editor rendering.
    public let aliases: [String]
    /// Optional creation timestamp for "recently added" UI. Nil-tolerant
    /// on load so a hand-edited file without the field still parses.
    public let createdAtUs: UInt64?

    public init(canonical: String, aliases: [String], createdAtUs: UInt64? = nil) {
        self.canonical = canonical
        self.aliases = aliases
        self.createdAtUs = createdAtUs
    }
}

/// Errors surfaced during dictionary load / validate / save.
public enum UserDictionaryError: Error, Equatable {
    /// The file exists but its content couldn't be parsed. String is a
    /// human-readable reason (line hint if available).
    case parseFailed(String)
    /// A dictionary invariant is violated (empty canonical, self-referential
    /// alias, duplicate canonical, etc). String is a human-readable reason.
    case validationFailed(String)
    /// Disk I/O failed (permission denied, disk full, etc).
    case ioFailed(String)
}

/// Top-level user dictionary — a versioned list of entries.
///
/// Validation invariants (checked in `validated()`):
///
///   1. Canonical name is non-empty and not whitespace-only.
///   2. No alias is empty or whitespace-only.
///   3. No canonical name appears twice (case-insensitive).
///   4. An alias is not equal to its own canonical (self-referential).
///
/// These are UX safety rails; a hand-edited file that violates them is
/// rejected at load time so the recall pipeline never sees garbage.
public struct UserDictionary: Sendable, Equatable, Codable {
    /// Storage format version. Bumped when the on-disk shape changes
    /// in a non-additive way. Current version: 1.
    public static let currentVersion: Int = 1

    public let version: Int
    public let entries: [UserDictionaryEntry]

    public init(entries: [UserDictionaryEntry] = [], version: Int = UserDictionary.currentVersion) {
        self.version = version
        self.entries = entries
    }

    /// The empty dictionary — what callers see when the on-disk file is
    /// missing. Safe to pass to the FFI: an empty alias map is a no-op.
    public static let empty = UserDictionary()

    /// Return `self` if all invariants hold; else throw
    /// `UserDictionaryError.validationFailed`. Called at load time and
    /// before every save so a bogus in-memory edit cannot be persisted.
    public func validated() throws -> UserDictionary {
        var seen = Set<String>()
        for entry in entries {
            let trimmed = entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw UserDictionaryError.validationFailed(
                    "canonical name must not be empty or whitespace-only"
                )
            }
            let lower = trimmed.lowercased()
            if seen.contains(lower) {
                throw UserDictionaryError.validationFailed(
                    "duplicate canonical name: \"\(entry.canonical)\""
                )
            }
            seen.insert(lower)
            for alias in entry.aliases {
                let aliasTrimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if aliasTrimmed.isEmpty {
                    throw UserDictionaryError.validationFailed(
                        "alias for \"\(entry.canonical)\" must not be empty or whitespace-only"
                    )
                }
                if aliasTrimmed.lowercased() == lower {
                    throw UserDictionaryError.validationFailed(
                        "alias \"\(alias)\" is the same as its canonical name \"\(entry.canonical)\""
                    )
                }
            }
        }
        return self
    }

    /// Project the dictionary into the alias-map shape the FFI consumes.
    /// Keys are canonical names, values are the alias list. Empty when
    /// the dictionary itself is empty. This is what `SearchViewModel`
    /// passes to `BrainReader.search`.
    public func toAliasMap() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for entry in entries {
            out[entry.canonical] = entry.aliases
        }
        return out
    }
}

// ---------------------------------------------------------------------------
// TOML round-trip — minimal hand-parser + serializer for our fixed shape
// ---------------------------------------------------------------------------
//
// We don't need a general TOML library. The file shape is closed:
//
//     version = <integer>
//     [[aliases]]
//     canonical = "<string>"
//     aliases = ["<s1>", "<s2>", ...]
//     created_at_us = <integer>   (optional)
//
// Adding a real TOML dependency (swift-toml / TOMLKit) is a Cargo/SwiftPM
// audit event; a fixed-shape hand-parser here keeps the dep surface at zero
// and is well under 100 LOC.

extension UserDictionary {
    /// Parse a TOML string of the fixed shape above. Blank lines and
    /// `# ...` comments are tolerated. Any other shape throws
    /// `UserDictionaryError.parseFailed`.
    public static func parseTOML(_ text: String) throws -> UserDictionary {
        var version = currentVersion
        var entries: [UserDictionaryEntry] = []
        var current: (canonical: String?, aliases: [String], createdAtUs: UInt64?)?

        func flush() throws {
            guard let cur = current else { return }
            guard let canonical = cur.canonical else {
                throw UserDictionaryError.parseFailed("[[aliases]] table missing canonical=")
            }
            entries.append(
                UserDictionaryEntry(
                    canonical: canonical,
                    aliases: cur.aliases,
                    createdAtUs: cur.createdAtUs
                )
            )
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "[[aliases]]" {
                try flush()
                current = (nil, [], nil)
                continue
            }
            guard let eqIdx = line.firstIndex(of: "=") else {
                throw UserDictionaryError.parseFailed("unexpected line: \(line)")
            }
            let key = line[..<eqIdx].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
            if current == nil {
                // Top-level keys: `version = N`.
                if key == "version" {
                    guard let v = Int(value) else {
                        throw UserDictionaryError.parseFailed("version must be an integer, got \(value)")
                    }
                    version = v
                } else {
                    throw UserDictionaryError.parseFailed("unexpected top-level key: \(key)")
                }
                continue
            }
            switch key {
            case "canonical":
                current?.canonical = try parseTOMLString(value)
            case "aliases":
                current?.aliases = try parseTOMLStringArray(value)
            case "created_at_us":
                current?.createdAtUs = UInt64(value)
            default:
                throw UserDictionaryError.parseFailed("unexpected [[aliases]] key: \(key)")
            }
        }
        try flush()
        return UserDictionary(entries: entries, version: version)
    }

    /// Serialize the dictionary to TOML. Round-trips through `parseTOML`.
    public func toTOML() -> String {
        var out = "# Hippocampus user dictionary — custom names + aliases.\n"
        out += "# Edit here or in Settings → Custom Names. Aliases match with high confidence\n"
        out += "# (the brain treats these as the same person/org/topic at query time).\n"
        out += "version = \(version)\n"
        for entry in entries {
            out += "\n[[aliases]]\n"
            out += "canonical = \(quoteTOMLString(entry.canonical))\n"
            let aliasParts = entry.aliases.map(quoteTOMLString).joined(separator: ", ")
            out += "aliases = [\(aliasParts)]\n"
            if let ts = entry.createdAtUs {
                out += "created_at_us = \(ts)\n"
            }
        }
        return out
    }
}

/// Parse one `"..."` TOML string literal. Supports the tiny escape set the
/// UI generates (`\"`, `\\`, `\n`); rejects other escapes so a garbage
/// escape sequence surfaces as a parse error rather than a silent mangling.
private func parseTOMLString(_ raw: String) throws -> String {
    guard raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 else {
        throw UserDictionaryError.parseFailed("expected quoted string, got \(raw)")
    }
    let inner = String(raw.dropFirst().dropLast())
    var out = ""
    var iter = inner.makeIterator()
    while let c = iter.next() {
        if c == "\\" {
            guard let esc = iter.next() else {
                throw UserDictionaryError.parseFailed("dangling escape in string: \(raw)")
            }
            switch esc {
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "n": out.append("\n")
            default:
                throw UserDictionaryError.parseFailed("unsupported escape \\\(esc) in \(raw)")
            }
        } else {
            out.append(c)
        }
    }
    return out
}

/// Parse a `["a", "b", "c"]` array of quoted strings.
private func parseTOMLStringArray(_ raw: String) throws -> [String] {
    guard raw.hasPrefix("["), raw.hasSuffix("]") else {
        throw UserDictionaryError.parseFailed("expected array, got \(raw)")
    }
    let inner = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    if inner.isEmpty { return [] }
    // Splitting on comma is safe here because the editor never emits a
    // literal comma inside an alias (see `UserDictionaryEditor` — commas
    // in the input string get treated as alias separators up-stream).
    var parts: [String] = []
    for piece in inner.split(separator: ",") {
        let trimmed = piece.trimmingCharacters(in: .whitespaces)
        parts.append(try parseTOMLString(trimmed))
    }
    return parts
}

/// Emit a `"..."` TOML string with our tiny escape set. Kept top-level so
/// unit tests can exercise the escape shape directly.
private func quoteTOMLString(_ s: String) -> String {
    var esc = ""
    for c in s {
        switch c {
        case "\"": esc.append("\\\"")
        case "\\": esc.append("\\\\")
        case "\n": esc.append("\\n")
        default: esc.append(c)
        }
    }
    return "\"\(esc)\""
}

// ---------------------------------------------------------------------------
// Disk I/O
// ---------------------------------------------------------------------------

/// Default on-disk location. `~/Library/Application Support/Hippocampus/`
/// (not `MCI/`) matches the product-facing product name; the SQLCipher
/// brain still lives under `MCI/mci.sqlite` for schema compat.
public func defaultUserDictionaryURL() -> URL {
    let supportDir = NSSearchPathForDirectoriesInDomains(
        .applicationSupportDirectory,
        .userDomainMask,
        true
    ).first ?? NSTemporaryDirectory()
    let dir = (supportDir as NSString).appendingPathComponent("Hippocampus")
    return URL(fileURLWithPath: dir).appendingPathComponent("user_dictionary.toml")
}

/// Load the user dictionary from disk. Missing file returns `.empty` —
/// the recall pipeline treats no-dictionary as no-aliases-applied (baseline
/// behavior). A present-but-malformed file throws so the editor can
/// surface a "your dictionary looks broken; please re-open the editor to
/// re-save" affordance rather than silently discarding the user's work.
public func loadUserDictionary(from url: URL = defaultUserDictionaryURL()) throws -> UserDictionary {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return .empty
    }
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw UserDictionaryError.ioFailed("read \(url.path): \(error)")
    }
    guard let text = String(data: data, encoding: .utf8) else {
        throw UserDictionaryError.parseFailed("non-UTF8 file at \(url.path)")
    }
    let parsed = try UserDictionary.parseTOML(text)
    return try parsed.validated()
}

/// Persist the dictionary to disk. Validates first — a bogus in-memory
/// edit never reaches the file. Creates the parent directory if needed.
public func saveUserDictionary(
    _ dictionary: UserDictionary,
    to url: URL = defaultUserDictionaryURL()
) throws {
    let validated = try dictionary.validated()
    let parent = url.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true
        )
    } catch {
        throw UserDictionaryError.ioFailed("mkdir \(parent.path): \(error)")
    }
    let text = validated.toTOML()
    do {
        try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
        throw UserDictionaryError.ioFailed("write \(url.path): \(error)")
    }
}
