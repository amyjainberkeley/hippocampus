// ChangelogParserTests.swift — pure-logic coverage for the
// CHANGELOG.md parser that feeds the "What's new" modal.

import XCTest
@testable import RecallUIKit

final class ChangelogParserTests: XCTestCase {

    // MARK: - Well-formed input

    private let sampleChangelog: String = """
    # Changelog

    All notable changes.

    ## [Unreleased] — 2026-07-13

    _Range: main~100..HEAD · 97 commit(s)._

    ### ✨ Features

    - **recall-ui:** global recall popup (`abcdef1`)
    - **brain:** SQLCipher integrity check on boot

    ### 🐛 Bug fixes

    - **dmg:** bake Qwen3 into the DMG

    ## [1.0.0] — 2026-06-01

    ### ✨ Features

    - initial public release

    """

    func test_parseAll_returns_all_releases_in_order() {
        let releases = ChangelogParser.parseAll(sampleChangelog)
        XCTAssertEqual(releases.count, 2)
        XCTAssertEqual(releases[0].version, "Unreleased")
        XCTAssertEqual(releases[0].date, "2026-07-13")
        XCTAssertEqual(releases[1].version, "1.0.0")
        XCTAssertEqual(releases[1].date, "2026-06-01")
    }

    func test_parses_sections_and_bullets() {
        let releases = ChangelogParser.parseAll(sampleChangelog)
        let unreleased = releases[0]
        XCTAssertEqual(unreleased.sections.count, 2)
        XCTAssertEqual(unreleased.sections[0].title, "Features")
        XCTAssertEqual(unreleased.sections[0].items.count, 2)
        XCTAssertTrue(unreleased.sections[0].items[0].hasPrefix("**recall-ui:**"))
        XCTAssertEqual(unreleased.sections[1].title, "Bug fixes")
        XCTAssertEqual(unreleased.sections[1].items.count, 1)
    }

    func test_stripSectionTitle_drops_leading_emoji() {
        XCTAssertEqual(ChangelogParser.stripSectionTitle("### ✨ Features"), "Features")
        XCTAssertEqual(ChangelogParser.stripSectionTitle("### 🐛 Bug fixes"), "Bug fixes")
        XCTAssertEqual(ChangelogParser.stripSectionTitle("### Docs"), "Docs")
    }

    func test_release_lookup_matches_exact_version() {
        let release = ChangelogParser.release(forVersion: "1.0.0", in: sampleChangelog)
        XCTAssertEqual(release?.version, "1.0.0")
        XCTAssertEqual(release?.sections.first?.items.first, "initial public release")
    }

    func test_release_lookup_case_insensitive_fallback() {
        let release = ChangelogParser.release(forVersion: "unreleased", in: sampleChangelog)
        XCTAssertEqual(release?.version, "Unreleased")
    }

    func test_release_lookup_returns_nil_for_missing_version() {
        XCTAssertNil(ChangelogParser.release(forVersion: "9.9.9", in: sampleChangelog))
    }

    // MARK: - Header parsing

    func test_parseVersionHeader_supports_em_dash() {
        let (version, date) = ChangelogParser.parseVersionHeader("## [1.2.3] — 2026-07-13")!
        XCTAssertEqual(version, "1.2.3")
        XCTAssertEqual(date, "2026-07-13")
    }

    func test_parseVersionHeader_supports_hyphen_separator() {
        let (version, date) = ChangelogParser.parseVersionHeader("## [1.2.3] - 2026-07-13")!
        XCTAssertEqual(version, "1.2.3")
        XCTAssertEqual(date, "2026-07-13")
    }

    func test_parseVersionHeader_supports_no_date() {
        let (version, date) = ChangelogParser.parseVersionHeader("## [Unreleased]")!
        XCTAssertEqual(version, "Unreleased")
        XCTAssertNil(date)
    }

    func test_parseVersionHeader_rejects_non_bracketed_header() {
        XCTAssertNil(ChangelogParser.parseVersionHeader("## Some plain heading"))
    }

    // MARK: - Degradation

    func test_empty_input_returns_empty_list() {
        XCTAssertEqual(ChangelogParser.parseAll("").count, 0)
    }

    func test_prose_only_input_returns_empty_list() {
        let prose = "# Changelog\n\nAll notable changes.\n\n"
        XCTAssertEqual(ChangelogParser.parseAll(prose).count, 0)
    }

    func test_release_with_no_sections_still_parses() {
        let src = "## [2.0.0] — 2026-08-01\n\n_Prose only._\n"
        let releases = ChangelogParser.parseAll(src)
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases[0].version, "2.0.0")
        XCTAssertTrue(releases[0].isEmpty)
    }

    func test_bullets_before_any_header_are_dropped() {
        // Defensive: if the top of the file has stray bullets (e.g.
        // an intro list before "## [..."), we skip them rather than
        // attaching to a phantom release.
        let src = "- stray\n- bullets\n\n## [1.0.0]\n\n### Features\n\n- real\n"
        let releases = ChangelogParser.parseAll(src)
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases[0].sections.first?.items, ["real"])
    }

    func test_supports_star_bullets() {
        let src = "## [1.0.0]\n\n### Features\n\n* star-bullet item\n"
        let releases = ChangelogParser.parseAll(src)
        XCTAssertEqual(releases[0].sections.first?.items, ["star-bullet item"])
    }
}
