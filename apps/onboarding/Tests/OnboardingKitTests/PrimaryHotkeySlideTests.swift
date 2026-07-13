// PrimaryHotkeySlideTests — cycle 8.48 (Raycast peer-study P0 #1).
//
// The SwiftUI view itself lives in the `Onboarding` executable target
// (not headless-testable from XCTest — SwiftUI's view tree, NSEvent
// monitors, and the frontmost-window predicate all need a real
// AppKit run-loop). What IS headless-testable is the state machine
// the slide drives: `hotkeyPracticed` flipping, `canAdvance` gating,
// and idempotency of `markHotkeyPracticed()`.
//
// Coverage:
//   1. Initial state — `hotkeyPracticed == false`, canAdvance == false
//      when currentStep is `.primaryHotkey`.
//   2. Live-try success — `markHotkeyPracticed()` flips the flag AND
//      unlocks Continue.
//   3. Skip fallback — same funnel; the slide's Skip button and its
//      hotkey monitor both call `markHotkeyPracticed()`.
//   4. Idempotency — a second call is a no-op (guards against a burst
//      of ⇧⌘Space presses re-triggering side effects).
//   5. `.primaryHotkey` sits immediately after `.permissions` in the
//      canonical step order (regression-guards the placement).

import XCTest
@testable import OnboardingKit

@MainActor
final class PrimaryHotkeySlideTests: XCTestCase {

    /// Build a flow VM already parked at the PrimaryHotkey step with
    /// all TCC granted (so Permissions doesn't gate advance).
    private func makeVM() -> OnboardingFlowViewModel {
        let vm = OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            automation: StubTCCPermission(kind: .automation, status: .granted),
            stateStore: InMemoryOnboardingStateStore()
        )
        vm.goTo(.primaryHotkey)
        return vm
    }

    func testInitialStateBlocksAdvance() {
        let vm = makeVM()
        XCTAssertEqual(vm.currentStep, .primaryHotkey)
        XCTAssertFalse(vm.hotkeyPracticed,
            "Fresh landing on PrimaryHotkey must start unpracticed")
        XCTAssertFalse(vm.canAdvance,
            "Continue must stay disabled until the user presses ⇧⌘Space or Skip")
    }

    func testLiveTryPressUnlocksContinue() {
        let vm = makeVM()
        // Simulates the NSEvent local-monitor path — the SwiftUI slide
        // funnels a real ⇧⌘Space press through `markHotkeyPracticed()`.
        vm.markHotkeyPracticed()
        XCTAssertTrue(vm.hotkeyPracticed)
        XCTAssertTrue(vm.canAdvance,
            "canAdvance must flip on live-try (or skip) — Continue unlocks")
    }

    func testSkipFallbackUnlocksContinueSameAsLiveTry() {
        // Same code path as the live-try (Skip button in the SwiftUI
        // slide just calls `markHotkeyPracticed()` directly). Modeled
        // as a distinct test so a future change that splits the two
        // paths must consciously break this and update it.
        let vm = makeVM()
        vm.markHotkeyPracticed()
        XCTAssertTrue(vm.canAdvance,
            "Skip fallback is REQUIRED for accessibility (SetApp/Alfred can grab ⇧⌘Space)")
    }

    func testMarkHotkeyPracticedIsIdempotent() {
        let vm = makeVM()
        vm.markHotkeyPracticed()
        vm.markHotkeyPracticed()
        vm.markHotkeyPracticed()
        XCTAssertTrue(vm.hotkeyPracticed,
            "Repeated presses must not toggle the flag off — one-shot latch")
    }

    func testPrimaryHotkeySitsBetweenPermissionsAndAllowlist() {
        XCTAssertEqual(OnboardingStep.permissions.rawValue + 1,
                       OnboardingStep.primaryHotkey.rawValue,
            "PrimaryHotkey must immediately follow Permissions — placement is load-bearing (Accessibility TCC just granted, muscle-memory moment).")
        XCTAssertEqual(OnboardingStep.primaryHotkey.rawValue + 1,
                       OnboardingStep.allowlist.rawValue,
            "Allowlist must immediately follow PrimaryHotkey — the flow reads 'permit → learn recall → configure what to remember'.")
    }

    func testAdvancingPastPrimaryHotkeyRequiresHotkeyPracticed() {
        let vm = makeVM()
        // Advance is a no-op while unpracticed.
        vm.advance()
        XCTAssertEqual(vm.currentStep, .primaryHotkey,
            "advance() must be a no-op while hotkeyPracticed == false")

        // Flip and try again.
        vm.markHotkeyPracticed()
        vm.advance()
        XCTAssertEqual(vm.currentStep, .allowlist,
            "advance() after markHotkeyPracticed() must reach .allowlist")
    }
}
