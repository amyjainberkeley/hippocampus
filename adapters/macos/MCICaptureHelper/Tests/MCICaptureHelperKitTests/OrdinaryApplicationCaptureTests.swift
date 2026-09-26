import XCTest
@testable import MCICaptureHelperKit

final class OrdinaryApplicationCaptureTests: XCTestCase {
    private struct Secure: SecureEventInputProbe {
        let enabled: Bool
        func isSecureEventInputEnabled() -> Bool { enabled }
    }
    private struct AX: AXSecureSubroleProbe {
        let secure: Bool?
        func focusedHasSecureSubrole() -> Bool? { secure }
    }
    private struct Blacked: BlackedRegionProbe {
        func hasBlackedRegion() -> Bool { false }
    }
    private func cascade(secure: Bool = false, ax: Bool? = false) -> SuppressionCascade {
        SuppressionCascade(
            secureEventInput: Secure(enabled: secure), axSecureSubrole: AX(secure: ax),
            denylist: SensitiveCaptureDenylist(entries: []), blackedRegion: Blacked(),
            rawPixelExcludedAppBundles: BrowserPixelCapturePolicy.excludedBundleIds,
            admissionPolicy: .ordinaryApplications
        )
    }
    func testOrdinaryIdentifiableAppsCaptureWithoutCatalogueEntry() {
        for bundle in ["com.openai.codex", "com.apple.TextEdit", "com.todesktop.230313mzl4w4u92"] {
            XCTAssertEqual(cascade().decide(context: WorkflowContext(appBundleId: bundle)), .allow)
        }
    }
    func testUnknownIdentityAndUncertainAccessibilityStillSuppress() {
        XCTAssertEqual(cascade().decide(context: WorkflowContext()), .suppress(reason: .failsafeUnknown))
        XCTAssertEqual(cascade(ax: nil).decide(context: WorkflowContext(appBundleId: "com.openai.codex")), .suppress(reason: .failsafeUnknown))
    }
    func testPositiveSecuritySignalsAlwaysWin() {
        let context = WorkflowContext(appBundleId: "com.openai.codex")
        XCTAssertEqual(cascade(secure: true).decide(context: context), .suppress(reason: .secureEventInput))
        XCTAssertEqual(cascade(ax: true).decide(context: context), .suppress(reason: .axSecureSubrole))
        XCTAssertEqual(cascade().decide(context: WorkflowContext(appBundleId: "com.1password.1password")), .suppress(reason: .denylistSource))
    }
    func testDomainExclusionsRespectHostBoundariesAndCase() {
        let denylist = SensitiveCaptureDenylist(entries: [])
        XCTAssertTrue(denylist.urlIsDenied("https://secure.CHASE.com/accounts"))
        XCTAssertTrue(denylist.urlIsDenied("https://chase.com"))
        XCTAssertFalse(denylist.urlIsDenied("https://chase.com.example.org/"))
        XCTAssertFalse(denylist.urlIsDenied("https://example.org/chase.com"))
        XCTAssertTrue(denylist.windowTitleIsDenied("New Tab (Incognito)"))
    }
    func testSensitiveApplicationExclusionsAreCaseInsensitive() {
        let denylist = SensitiveCaptureDenylist(entries: [])
        for bundle in ["com.apple.Passwords", "com.dashlane.Dashlane", "com.lastpass.LastPass"] {
            XCTAssertTrue(denylist.appIsDenied(bundleId: bundle))
            XCTAssertTrue(denylist.appIsDenied(bundleId: bundle.uppercased()))
        }
    }
    func testBrowserRemainsExcludedWithoutPositiveNormalWindowEvidence() {
        XCTAssertEqual(cascade().decide(context: WorkflowContext(appBundleId: "com.google.Chrome")), .suppress(reason: .failsafeUnknown))
    }

    func testMemorySurfacesDoNotRecaptureTheirOwnEvidence() {
        for bundle in ["ai.hippocampus", "recall-ui", "onboarding"] {
            XCTAssertEqual(cascade().decide(context: WorkflowContext(appBundleId: bundle)),
                           .suppress(reason: .denylistSource))
        }
        XCTAssertEqual(cascade().decide(context: WorkflowContext(appBundleId: "ai.hippocampus.CaptureOverlapCorpus")), .allow)
    }

    func testSystemPermissionDialogsNeverBecomeMemory() {
        for bundle in ["com.apple.UserNotificationCenter", "com.apple.SecurityAgent"] {
            XCTAssertEqual(cascade().decide(context: WorkflowContext(appBundleId: bundle)),
                           .suppress(reason: .denylistSource))
        }
    }
}
