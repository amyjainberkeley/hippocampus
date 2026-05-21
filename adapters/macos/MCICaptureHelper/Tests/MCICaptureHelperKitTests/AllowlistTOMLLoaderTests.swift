// SPDX-License-Identifier: TBD-private
//
// AllowlistTOMLLoaderTests — ADR-0013 §3 + ADR-0015 §5 + ADR-0017 §3.1
// CSO-ratified known-safe-apps allowlist loader.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. These tests pin both the parser
// surface (strict TOML subset; refuse anything malformed) AND the
// bundled seed contract (the 10 ratified bundle ids load cleanly,
// every one resolves via `Allowlist.contains(_:)`, unknowns return
// false). A regression in either is a LAUNCH-BLOCKER:
//   - parser regressions weaken the trust boundary the loader is
//     supposed to enforce.
//   - seed-file regressions either disable the cascade's §1 source-
//     level allow path (no app ratified → no .allow → empty brain →
//     no demo) or worse, smuggle an unintended app into the allowlist.

import XCTest

@testable import MCICaptureHelperKit

// MARK: - Loader happy path

final class AllowlistTOMLLoaderHappyPathTests: XCTestCase {
    func testEmptyDocumentParsesToZeroEntries() throws {
        let loader = AllowlistTOMLLoader()
        let entries = try loader.parse("")
        XCTAssertTrue(entries.isEmpty)
    }

    func testOnlyCommentsAndBlanksParsesToZeroEntries() throws {
        let loader = AllowlistTOMLLoader()
        let entries = try loader.parse("""
        # MCI known-safe-apps
        # CSO-ratified bundles

        # add entries below
        """)
        XCTAssertTrue(entries.isEmpty)
    }

    func testSingleAllowlistEntry() throws {
        let loader = AllowlistTOMLLoader()
        let entries = try loader.parse("""
        [[entries]]
        bundle_id = "com.apple.Safari"
        rationale = "Web browser."
        cso_ratified_by = "orchestrator-seat"
        ratified_at = "2026-05-20"
        """)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].bundleId, "com.apple.Safari")
        XCTAssertEqual(entries[0].rationale, "Web browser.")
        XCTAssertEqual(entries[0].csoRatifiedBy, "orchestrator-seat")
        XCTAssertEqual(entries[0].ratifiedAt, "2026-05-20")
    }

    func testMultipleEntriesInDocumentOrder() throws {
        let loader = AllowlistTOMLLoader()
        let entries = try loader.parse("""
        [[entries]]
        bundle_id = "com.apple.Safari"
        rationale = "Safari."
        cso_ratified_by = "orchestrator-seat"
        ratified_at = "2026-05-20"

        [[entries]]
        bundle_id = "com.google.Chrome"
        rationale = "Chrome."
        cso_ratified_by = "orchestrator-seat"
        ratified_at = "2026-05-20"
        """)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].bundleId, "com.apple.Safari")
        XCTAssertEqual(entries[1].bundleId, "com.google.Chrome")
    }

    func testKeyOrderInsideTableDoesNotMatter() throws {
        let loader = AllowlistTOMLLoader()
        let entries = try loader.parse("""
        [[entries]]
        ratified_at = "2026-05-20"
        rationale = "Test."
        cso_ratified_by = "orchestrator-seat"
        bundle_id = "com.example.app"
        """)
        XCTAssertEqual(entries[0].bundleId, "com.example.app")
        XCTAssertEqual(entries[0].rationale, "Test.")
    }

    /// End-to-end: parsed entries feed an `Allowlist` value, which
    /// `SuppressionCascade` reads via `bundleIdSet`.
    func testParsedEntriesFeedAllowlistMatcher() throws {
        let loader = AllowlistTOMLLoader()
        let entries = try loader.parse("""
        [[entries]]
        bundle_id = "com.apple.Safari"
        rationale = "Safari."
        cso_ratified_by = "orchestrator-seat"
        ratified_at = "2026-05-20"
        """)
        let allowlist = Allowlist(entries: entries)
        XCTAssertTrue(allowlist.contains("com.apple.Safari"))
        XCTAssertFalse(allowlist.contains("com.example.UnknownApp"))
        XCTAssertEqual(allowlist.bundleIdSet, ["com.apple.Safari"])
    }
}

// MARK: - Loader hostile-input rejection

final class AllowlistTOMLLoaderRejectsHostileInputTests: XCTestCase {
    func testRejectsUnexpectedLineOutsideTable() {
        let loader = AllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("bundle_id = \"com.x\"")) { err in
            XCTAssertEqual(err as? AllowlistTOMLError, .unexpectedLine(line: 1))
        }
    }

    func testRejectsMissingBundleId() {
        let loader = AllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        rationale = "Test."
        cso_ratified_by = "orchestrator-seat"
        ratified_at = "2026-05-20"
        """)) { err in
            XCTAssertEqual(err as? AllowlistTOMLError, .missingBundleId(line: 1))
        }
    }

    func testRejectsMissingRationale() {
        let loader = AllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        bundle_id = "com.x"
        cso_ratified_by = "orchestrator-seat"
        ratified_at = "2026-05-20"
        """)) { err in
            XCTAssertEqual(err as? AllowlistTOMLError, .missingRationale(line: 1))
        }
    }

    func testRejectsMissingCsoRatifiedBy() {
        let loader = AllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        bundle_id = "com.x"
        rationale = "Test."
        ratified_at = "2026-05-20"
        """)) { err in
            XCTAssertEqual(err as? AllowlistTOMLError, .missingCsoRatifiedBy(line: 1))
        }
    }

    func testRejectsMissingRatifiedAt() {
        let loader = AllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        bundle_id = "com.x"
        rationale = "Test."
        cso_ratified_by = "orchestrator-seat"
        """)) { err in
            XCTAssertEqual(err as? AllowlistTOMLError, .missingRatifiedAt(line: 1))
        }
    }

    func testRejectsEmptyBundleId() {
        let loader = AllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        bundle_id = ""
        rationale = "Test."
        cso_ratified_by = "orchestrator-seat"
        ratified_at = "2026-05-20"
        """)) { err in
            XCTAssertEqual(err as? AllowlistTOMLError, .emptyValue(line: 2, key: "bundle_id"))
        }
    }

    func testRejectsUnquotedValue() {
        let loader = AllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        bundle_id = com.x
        rationale = "Test."
        cso_ratified_by = "orchestrator-seat"
        ratified_at = "2026-05-20"
        """)) { err in
            XCTAssertEqual(err as? AllowlistTOMLError, .malformedKvLine(line: 2))
        }
    }

    func testRejectsEscapeSequenceInValue() {
        let loader = AllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        bundle_id = "com.\\x"
        rationale = "Test."
        cso_ratified_by = "orchestrator-seat"
        ratified_at = "2026-05-20"
        """)) { err in
            XCTAssertEqual(err as? AllowlistTOMLError, .malformedKvLine(line: 2))
        }
    }

    func testRejectsDuplicateBundleIdInOneTable() {
        let loader = AllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        bundle_id = "com.x"
        bundle_id = "com.y"
        rationale = "Test."
        cso_ratified_by = "orchestrator-seat"
        ratified_at = "2026-05-20"
        """)) { err in
            XCTAssertEqual(err as? AllowlistTOMLError, .duplicateKey(line: 3, key: "bundle_id"))
        }
    }

    func testRejectsUnknownKey() {
        let loader = AllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        bundle_id = "com.x"
        rationale = "Test."
        cso_ratified_by = "orchestrator-seat"
        ratified_at = "2026-05-20"
        expires_at = "2027-01-01"
        """)) { err in
            XCTAssertEqual(err as? AllowlistTOMLError, .malformedKvLine(line: 6))
        }
    }
}

// MARK: - Bundled seed contract

/// The 10 CSO-ratified bundle ids that MUST round-trip through the
/// bundled seed file. Hard-coding them here is deliberate — a silent
/// drop or rename of any of these in `known-safe-apps.toml` requires
/// either updating this list (with an ADR amendment) or failing this
/// test loudly. Both are good outcomes.
private let expectedBundledSeedBundles: Set<String> = [
    "com.apple.Safari",
    "com.apple.Terminal",
    "com.microsoft.VSCode",
    "com.google.Chrome",
    "com.tinyspeck.slackmacgap",
    "notion.id",
    "com.linear.LinearMac",
    "com.apple.dt.Xcode",
    "company.thebrowser.Browser",
    "com.figma.Desktop",
]

final class AllowlistBundledSeedTests: XCTestCase {
    /// The bundled `known-safe-apps.toml` MUST load without throwing —
    /// it's the CSO-ratified trust artifact and any parse failure is a
    /// signed-bundle defect.
    func testBundledSeedLoadsCleanly() throws {
        let allowlist = try AllowlistTOMLLoader.loadBundled()
        XCTAssertEqual(allowlist.entries.count, expectedBundledSeedBundles.count)
    }

    func testBundledSeedContainsEveryExpectedBundle() throws {
        let allowlist = try AllowlistTOMLLoader.loadBundled()
        for bundleId in expectedBundledSeedBundles {
            XCTAssertTrue(
                allowlist.contains(bundleId),
                "Bundled allowlist seed missing CSO-ratified bundle: \(bundleId)"
            )
        }
    }

    /// Allowlist is STRICT — an unknown bundle must return false. This
    /// is the inverse of the contract above and pins the trust gate:
    /// "anything not ratified is not allowed."
    func testBundledSeedRefusesUnknownBundles() throws {
        let allowlist = try AllowlistTOMLLoader.loadBundled()
        XCTAssertFalse(allowlist.contains("com.example.UnknownApp"))
        XCTAssertFalse(allowlist.contains(""))
        XCTAssertFalse(allowlist.contains("com.apple.Safari.UNKNOWN"))
    }

    /// The seed's `bundleIdSet` is the exact Set the helper feeds to
    /// `SuppressionCascade(knownSafeAppBundles:)`. Equal-set assertion
    /// pins both the count AND the membership in one shot.
    func testBundledSeedBundleIdSetMatchesExpected() throws {
        let allowlist = try AllowlistTOMLLoader.loadBundled()
        XCTAssertEqual(allowlist.bundleIdSet, expectedBundledSeedBundles)
    }
}
