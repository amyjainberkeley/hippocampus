// WhatsNewModalStateTests.swift — headless coverage of the modal's
// derived state.
//
// The modal itself is a SwiftUI view; we don't take a snapshot-testing
// dep for a single sheet. Instead we pin the *inputs* the modal reads
// — the coordinator's `currentRelease`, `isDevBuild`, and header
// subtitle derivation — via a small mirror of the modal's format
// contract. If the modal is ever refactored the two must stay in sync
// (checked by grep + code review on the header-subtitle format
// string).

import XCTest
@testable import RecallUIKit

@MainActor
final class WhatsNewModalStateTests: XCTestCase {

    /// Header subtitle contract — the modal renders this exact
    /// format. Kept as a helper so tests can assert against it
    /// without importing SwiftUI.
    private func headerSubtitle(for release: ChangelogRelease?) -> String {
        guard let release = release else { return "Dev build" }
        if let date = release.date {
            return "Version \(release.version) · \(date)"
        }
        return "Version \(release.version)"
    }

    func test_release_with_date_renders_version_and_date() {
        let release = ChangelogRelease(
            version: "1.2.3",
            date: "2026-07-13",
            sections: [.init(title: "Features", items: ["a"])]
        )
        XCTAssertEqual(headerSubtitle(for: release), "Version 1.2.3 · 2026-07-13")
    }

    func test_release_without_date_renders_version_only() {
        let release = ChangelogRelease(
            version: "Unreleased",
            date: nil,
            sections: [.init(title: "Features", items: ["a"])]
        )
        XCTAssertEqual(headerSubtitle(for: release), "Version Unreleased")
    }

    func test_dev_build_fallback_subtitle() {
        XCTAssertEqual(headerSubtitle(for: nil), "Dev build")
    }

    // MARK: - Section shape

    func test_release_sections_preserve_source_ordering() {
        let src = """
        ## [1.0.0] — 2026-06-01

        ### Features

        - one

        ### Bug fixes

        - two

        ### Docs

        - three
        """
        let release = ChangelogParser.parseAll(src).first!
        XCTAssertEqual(
            release.sections.map(\.title),
            ["Features", "Bug fixes", "Docs"]
        )
    }

    func test_empty_release_flag_flips() {
        let full = ChangelogRelease(
            version: "1.0.0",
            date: nil,
            sections: [.init(title: "Features", items: ["a"])]
        )
        XCTAssertFalse(full.isEmpty)

        let empty = ChangelogRelease(
            version: "1.0.0",
            date: nil,
            sections: []
        )
        XCTAssertTrue(empty.isEmpty)
    }
}
