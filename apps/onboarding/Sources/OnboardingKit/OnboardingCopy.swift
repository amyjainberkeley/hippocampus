import Foundation

/// Load-bearing user-facing copy strings that are asserted on by
/// `OnboardingKitTests`. Kept in `OnboardingKit` (not in the SwiftUI
/// slide files) so tests can hold ground truth without importing the
/// executable target.
///
/// Why this exists (cycle 8.38 onboarding audit, PR-2):
/// - Fix (a) The `howItWorksFootprint` copy must reflect the
///   2026-05-31 amended footprint SLO (≤ 10–15% CPU / ≤ 2 GB RAM).
///   The prior "under 2% CPU / under 250 MB RAM" string set the
///   user's expectation 5× too aggressive — CEO Amy flagged this as a
///   trust-budget bug on the CRS 8.32 scan.
/// - Fix (b) The `welcomeRewindSubheader` copy is triggered by a
///   `onboarding://start?migration=rewind` deep-link fired from the
///   `/rewind` landing lane (cycle 8.37 PR #30).
/// - Fix (c) `doneMenuBarHint` replaces the previous shortcut promises
///   for `⇧⌘F` / `⇧⌘P` — neither is bound anywhere in HippocampusApp,
///   so the copy is a plain-English menu-bar reminder instead of a lie.
public enum OnboardingCopy {
    /// `HowItWorksSlide` featureRow — footprint SLO paraphrase for
    /// non-technical users. Must contain "15%" and "2 GB" so any
    /// future edit that regresses to the pre-2026-05-31 tight bar
    /// (or drops the amended numbers entirely) fails a unit test.
    public static let howItWorksFootprint = "Runs quietly in the background — typically under 15% of one CPU core and under 2 GB of memory during a full-day session."

    /// `WelcomeSlide` sub-header shown only when the flow VM's
    /// `migrationSource == .rewind`. Copy chosen to reassure a
    /// user coming from Rewind's 2025-12-19 sunset that Hippocampus
    /// is fully local — the biggest concern of the ex-Rewind cohort
    /// per the CRS 8.37 competitor scan.
    public static let welcomeRewindSubheader = "Welcome from Rewind. Your data stays on your Mac — nothing uploaded, nothing shared."

    /// `DoneSlide` — replaces the previous `⇧⌘F` / `⇧⌘P` shortcut
    /// promises. Do NOT add hotkey copy back unless `HippocampusApp`
    /// actually binds a global hotkey (recall-UI audit PR-5).
    public static let doneMenuBarHint = "You can open Hippocampus from the menu bar icon anytime."
}
