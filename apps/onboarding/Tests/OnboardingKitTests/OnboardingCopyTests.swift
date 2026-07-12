import XCTest
@testable import OnboardingKit

/// Cycle 8.38 onboarding audit PR-2 — copy invariants.
///
/// These tests hold the load-bearing user-facing strings for three
/// slides. `Sources/Onboarding/Slides/*.swift` (executable target)
/// reads from `OnboardingCopy.*` — so if any of these constants is
/// silently regressed to old copy (or the amended footprint SLO is
/// dropped), the test suite fails before the slide can ship.
///
/// Do NOT weaken these assertions without a corresponding audit-doc
/// note — they exist to prevent regression to:
///   - "Less than 2% CPU, under 250 MB RAM" (pre-2026-05-31 tight bar)
///   - "⇧⌘F" / "⇧⌘P" as advertised-but-unbound global shortcuts
final class OnboardingCopyTests: XCTestCase {

    // MARK: - Fix (a): HowItWorksSlide footprint SLO

    func testHowItWorksFootprintMentionsAmendedCPUTarget() {
        // 2026-05-31 amended SLO — steady-state ≤ 10–15% CPU.
        // The copy must contain "15%" so a well-meaning edit to
        // "under one CPU" doesn't quietly drop the number.
        XCTAssertTrue(
            OnboardingCopy.howItWorksFootprint.contains("15%"),
            "HowItWorks footprint copy must cite the amended 15% CPU target."
        )
    }

    func testHowItWorksFootprintMentionsAmendedRAMTarget() {
        XCTAssertTrue(
            OnboardingCopy.howItWorksFootprint.contains("2 GB"),
            "HowItWorks footprint copy must cite the amended 2 GB RAM target."
        )
    }

    func testHowItWorksFootprintDoesNotRegressToOldSLO() {
        // Regression guard — the prior copy was
        // "Less than 2% CPU, under 250 MB RAM" and set expectation
        // 5× too aggressive relative to the amended default tier.
        let copy = OnboardingCopy.howItWorksFootprint
        XCTAssertFalse(copy.contains("2% CPU"), "Stale pre-2026-05-31 CPU claim.")
        XCTAssertFalse(copy.contains("250 MB"), "Stale pre-2026-05-31 RAM claim.")
    }

    // MARK: - Fix (b): WelcomeSlide Rewind-migrator sub-header

    func testWelcomeRewindSubheaderNamesRewindExplicitly() {
        XCTAssertTrue(
            OnboardingCopy.welcomeRewindSubheader.contains("Rewind"),
            "Rewind-migrator sub-header must name the source product."
        )
    }

    func testWelcomeRewindSubheaderReassuresLocalOnly() {
        // The 8.37 CRS competitor scan identified the ex-Rewind cohort's
        // top concern as "does this leave my Mac?" — the sub-header must
        // answer explicitly.
        let copy = OnboardingCopy.welcomeRewindSubheader
        XCTAssertTrue(
            copy.contains("stays on your Mac") ||
            copy.contains("nothing uploaded"),
            "Rewind sub-header must reassure local-only."
        )
    }

    // MARK: - Fix (c): DoneSlide unbound-shortcut promises removed

    func testDoneMenuBarHintDoesNotPromiseUnboundShortcuts() {
        // The prior DoneSlide advertised these two global hotkeys.
        // Neither is bound by HippocampusApp today (recall-UI audit
        // Friction #0). Regressing to shortcut copy without also
        // binding the hotkey ships a lie.
        let copy = OnboardingCopy.doneMenuBarHint
        XCTAssertFalse(copy.contains("\u{21E7}\u{2318}F"),
            "DoneSlide must not promise ⇧⌘F until it's bound.")
        XCTAssertFalse(copy.contains("\u{21E7}\u{2318}P"),
            "DoneSlide must not promise ⇧⌘P until it's bound.")
    }

    func testDoneMenuBarHintPointsAtMenuBar() {
        XCTAssertTrue(
            OnboardingCopy.doneMenuBarHint.lowercased().contains("menu bar"),
            "DoneSlide must point the user at the menu-bar entrypoint."
        )
    }
}
