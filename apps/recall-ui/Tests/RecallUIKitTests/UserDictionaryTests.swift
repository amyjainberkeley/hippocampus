// UserDictionaryTests.swift — cycle 8.42 coverage for the user dictionary
// model + TOML round-trip + validation.
//
// Tests cover:
//   1. Empty dictionary round-trips through TOML.
//   2. Non-trivial dictionary round-trips (canonical + aliases + escapes).
//   3. Validation rejects: empty canonical, empty alias, self-referential
//      alias, duplicate canonical (case-insensitive).
//   4. `toAliasMap()` projects into the FFI-shaped map.
//   5. Load-from-missing-file returns `.empty` (no throw).
//   6. Malformed TOML throws `.parseFailed`.

import XCTest
@testable import RecallUIKit

final class UserDictionaryTests: XCTestCase {

    // -----------------------------------------------------------------
    // 1. Empty round trip
    // -----------------------------------------------------------------
    func testEmptyDictionaryRoundTripsThroughTOML() throws {
        let d = UserDictionary.empty
        let toml = d.toTOML()
        let parsed = try UserDictionary.parseTOML(toml)
        XCTAssertEqual(parsed.entries.count, 0)
        XCTAssertEqual(parsed.version, UserDictionary.currentVersion)
    }

    // -----------------------------------------------------------------
    // 2. Non-trivial round trip with a real payload
    // -----------------------------------------------------------------
    func testCanonicalAndAliasesRoundTrip() throws {
        let d = UserDictionary(entries: [
            UserDictionaryEntry(
                canonical: "Amy Jain",
                aliases: ["AJ", "Amy", "@amyjainberkeley"],
                createdAtUs: 1_700_000_000_000_000
            ),
            UserDictionaryEntry(
                canonical: "Hippocampus",
                aliases: ["MCI", "the memory app"]
            ),
        ])
        let toml = d.toTOML()
        let back = try UserDictionary.parseTOML(toml)
        XCTAssertEqual(back.entries.count, 2)
        XCTAssertEqual(back.entries[0].canonical, "Amy Jain")
        XCTAssertEqual(back.entries[0].aliases, ["AJ", "Amy", "@amyjainberkeley"])
        XCTAssertEqual(back.entries[0].createdAtUs, 1_700_000_000_000_000)
        XCTAssertEqual(back.entries[1].canonical, "Hippocampus")
        XCTAssertEqual(back.entries[1].aliases, ["MCI", "the memory app"])
    }

    func testEscapedCharactersRoundTrip() throws {
        // Aliases containing quotes, backslashes, and newlines must survive
        // the TOML escape round-trip.
        let d = UserDictionary(entries: [
            UserDictionaryEntry(
                canonical: #"weird "name""#,
                aliases: [#"back\slash"#, "line\nbreak"]
            )
        ])
        let toml = d.toTOML()
        let back = try UserDictionary.parseTOML(toml)
        XCTAssertEqual(back.entries[0].canonical, #"weird "name""#)
        XCTAssertEqual(back.entries[0].aliases, [#"back\slash"#, "line\nbreak"])
    }

    // -----------------------------------------------------------------
    // 3. Validation
    // -----------------------------------------------------------------
    func testValidationRejectsEmptyCanonical() {
        let d = UserDictionary(entries: [
            UserDictionaryEntry(canonical: "   ", aliases: ["AJ"])
        ])
        XCTAssertThrowsError(try d.validated()) { err in
            guard case UserDictionaryError.validationFailed = err else {
                return XCTFail("expected validationFailed, got \(err)")
            }
        }
    }

    func testValidationRejectsEmptyAlias() {
        let d = UserDictionary(entries: [
            UserDictionaryEntry(canonical: "Amy Jain", aliases: ["AJ", "  "])
        ])
        XCTAssertThrowsError(try d.validated())
    }

    func testValidationRejectsSelfReferentialAlias() {
        let d = UserDictionary(entries: [
            UserDictionaryEntry(canonical: "Amy Jain", aliases: ["amy jain"])
        ])
        XCTAssertThrowsError(try d.validated()) { err in
            guard case UserDictionaryError.validationFailed(let msg) = err else {
                return XCTFail("expected validationFailed, got \(err)")
            }
            XCTAssertTrue(msg.contains("same as its canonical"), "got: \(msg)")
        }
    }

    func testValidationRejectsDuplicateCanonicalCaseInsensitive() {
        let d = UserDictionary(entries: [
            UserDictionaryEntry(canonical: "Amy Jain", aliases: ["AJ"]),
            UserDictionaryEntry(canonical: "amy jain", aliases: ["A"]),
        ])
        XCTAssertThrowsError(try d.validated()) { err in
            guard case UserDictionaryError.validationFailed(let msg) = err else {
                return XCTFail("expected validationFailed, got \(err)")
            }
            XCTAssertTrue(msg.contains("duplicate"), "got: \(msg)")
        }
    }

    // -----------------------------------------------------------------
    // 4. toAliasMap — FFI wire shape
    // -----------------------------------------------------------------
    func testToAliasMapProjectsCanonicalToAliases() {
        let d = UserDictionary(entries: [
            UserDictionaryEntry(canonical: "Amy Jain", aliases: ["AJ", "Amy"]),
            UserDictionaryEntry(canonical: "Hippocampus", aliases: ["MCI"]),
        ])
        let m = d.toAliasMap()
        XCTAssertEqual(m["Amy Jain"], ["AJ", "Amy"])
        XCTAssertEqual(m["Hippocampus"], ["MCI"])
        XCTAssertEqual(m.count, 2)
    }

    // -----------------------------------------------------------------
    // 5. Missing file → empty
    // -----------------------------------------------------------------
    func testLoadFromMissingFileReturnsEmpty() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mci-userdict-\(UUID().uuidString).toml")
        let d = try loadUserDictionary(from: tmp)
        XCTAssertEqual(d.entries.count, 0)
    }

    // -----------------------------------------------------------------
    // 6. Malformed TOML throws parseFailed
    // -----------------------------------------------------------------
    func testMalformedTOMLThrowsParseFailed() {
        XCTAssertThrowsError(try UserDictionary.parseTOML("garbage without equals")) { err in
            guard case UserDictionaryError.parseFailed = err else {
                return XCTFail("expected parseFailed, got \(err)")
            }
        }
    }

    // -----------------------------------------------------------------
    // 7. End-to-end disk round trip
    // -----------------------------------------------------------------
    func testSaveThenLoadPreservesEntries() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mci-userdict-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let d = UserDictionary(entries: [
            UserDictionaryEntry(canonical: "Amy Jain", aliases: ["AJ"])
        ])
        try saveUserDictionary(d, to: tmp)
        let back = try loadUserDictionary(from: tmp)
        XCTAssertEqual(back.entries.count, 1)
        XCTAssertEqual(back.entries[0].canonical, "Amy Jain")
        XCTAssertEqual(back.entries[0].aliases, ["AJ"])
    }
}
