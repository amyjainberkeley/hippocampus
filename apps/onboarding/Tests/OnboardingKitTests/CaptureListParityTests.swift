import XCTest
@testable import OnboardingKit

/// Try it tells the person why an app in front is not read. The lists it
/// uses copy the capture helper's, which onboarding does not link; these
/// tests hold the copies to the helper's sources.
final class CaptureListParityTests: XCTestCase {
    private let suppression = repositoryRoot
        .appendingPathComponent("adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression")

    /// The quoted strings of the collection literal that follows `marker`.
    private func quotedStrings(after marker: String, in file: String, keysOnly: Bool = false) throws -> Set<String> {
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
        let pattern = keysOnly ? #""([^"]+)"\s*:"# : #""([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(literal.startIndex..., in: literal)
        return Set(regex.matches(in: literal, range: range).compactMap { match in
            Range(match.range(at: 1), in: literal).map { String(literal[$0]) }
        })
    }

    func testNeverReadAppsMatchTheHelpersList() throws {
        let helper = try quotedStrings(after: "public static let appBundles: Set<String> =", in: "CaptureAdmissionPolicy.swift")
        let own: Set<String> = ["ai.hippocampus", "recall-ui", "onboarding"]
        XCTAssertEqual(FrontAppNote.neverReadApps, helper.subtracting(own))
        XCTAssertEqual(ReadProof.ownBundleIds, helper.intersection(own))
    }

    func testBrowserListsMatchTheHelpersLists() throws {
        let excluded = try quotedStrings(after: "public static let excludedBundleIds: Set<String> =", in: "BrowserPixelCapturePolicy.swift")
        XCTAssertEqual(FrontAppNote.pixelExcludedBrowsers, excluded)
        let checked = try quotedStrings(after: "internal static let scripts: [String: String] =", in: "BrowserWindowPrivacyProbe.swift", keysOnly: true)
        XCTAssertEqual(FrontAppNote.privacyCheckedBrowsers, checked)
    }
}
