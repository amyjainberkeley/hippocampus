import XCTest
@testable import OnboardingKit

/// Try it tells the person why the window in front is not read. The rules it
/// uses copy the capture helper's, which onboarding does not link; these
/// tests hold the copies to the helper's source. Browsers are read like
/// every other window (RULINGS G8); the browser list is copied only to say
/// when a window shows it is private.
final class CaptureListParityTests: XCTestCase {
    private let suppression = repositoryRoot
        .appendingPathComponent("adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression")

    /// The quoted strings of the collection literal that follows `marker`.
    private func quotedStrings(after marker: String, in file: String) throws -> Set<String> {
        let source = try String(contentsOf: suppression.appendingPathComponent(file), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: marker), "\(marker) not found in \(file)")
        let open = try XCTUnwrap(source[start.upperBound...].firstIndex(of: "["))
        var depth = 0
        var end = open
        for index in source[open...].indices {
            if source[index] == "[" { depth += 1 }
            if source[index] == "]" { depth -= 1 }
            if depth == 0 { end = index; break }
        }
        let literal = String(source[open...end])
        let regex = try NSRegularExpression(pattern: #""([^"]+)""#)
        let range = NSRange(literal.startIndex..., in: literal)
        return Set(regex.matches(in: literal, range: range).compactMap { match in
            Range(match.range(at: 1), in: literal).map { String(literal[$0]) }
        })
    }

    func testNeverReadAppsMatchTheHelpersList() throws {
        // The helper splits its never-read identifiers into two constants:
        // `appBundles` (system agents, matched exactly) and
        // `passwordManagerFamilies` (password managers and authenticators,
        // matched by identifier family). Try it copies both, and these
        // assertions hold the copies to the helper's source.
        let appBundles = try quotedStrings(
            after: "public static let appBundles: Set<String> =", in: "CaptureAdmissionPolicy.swift")
        let families = try quotedStrings(
            after: "public static let passwordManagerFamilies: Set<String> =", in: "CaptureAdmissionPolicy.swift")
        let own: Set<String> = ["ai.hippocampus", "recall-ui", "onboarding"]

        // Hippocampus's own apps are never read because they are memory
        // viewers, not system agents; `ReadProof` owns that list, and it is
        // exactly the overlap between `own` and the helper's `appBundles`.
        XCTAssertEqual(ReadProof.ownBundleIds, own)
        XCTAssertEqual(ReadProof.ownBundleIds, appBundles.intersection(own))

        // The system agents the card names (exact match) are the helper's
        // `appBundles` minus Hippocampus's own apps — no more, no less.
        XCTAssertEqual(ReadRules.neverReadApps, appBundles.subtracting(own))

        // The password-manager families the card matches by prefix are the
        // helper's `passwordManagerFamilies`, exactly, so the "never read"
        // note covers every password manager and authenticator the helper
        // drops rather than a hand-picked subset.
        XCTAssertEqual(ReadRules.neverReadPasswordManagerFamilies, families)

        // The two helper constants partition its never-read set (they never
        // double-list an identifier); onboarding checks both the same way the
        // helper does (`ReadRules.isNeverRead` mirrors
        // `SensitiveCaptureDenylist.isNeverReadApp`).
        XCTAssertTrue(appBundles.isDisjoint(with: families))
    }

    func testPrivateWindowsAreKnownByTheHelpersBrowsersAndTitleMarkers() throws {
        let browsers = try quotedStrings(
            after: "public static let browserBundleIds: Set<String> =", in: "BrowserPixelCapturePolicy.swift")
        XCTAssertEqual(ReadRules.browserBundleIds, browsers)
        let markers = try quotedStrings(
            after: "static let privateTitleMarkers =", in: "BrowserPixelCapturePolicy.swift")
        XCTAssertEqual(Set(ReadRules.privateTitleMarkers), markers)
    }

    func testThePersonsExclusionsAreReadFromTheFileTheHelperReads() throws {
        let main = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "adapters/macos/MCICaptureHelper/Sources/MCICaptureHelper/main.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains(#"appendingPathComponent("MCI").appendingPathComponent("denylist.toml")"#))
        XCTAssertEqual(PersonExclusions.defaultURL?.pathComponents.suffix(2), ["MCI", "denylist.toml"])
        let loader = try String(contentsOf: suppression.appendingPathComponent("DenylistTOMLLoader.swift"),
                                encoding: .utf8)
        XCTAssertTrue(loader.contains(#"entry-table    = "[[denylist]]" newline"#))
        XCTAssertTrue(loader.contains("`appBundle`"), "the kind Try it reads")
    }
}
