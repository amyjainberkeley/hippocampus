// SPDX-License-Identifier: Apache-2.0
//
// Setup's Try it reads the person's real window in front. When the person
// brings a window forward while it shows, setup asks the app for one fresh
// read of it, as opening Ask does (`ProcessSupervisor.requestFreshRead`):
// otherwise the new window waits for the reader's rest, which can be many
// seconds on battery. Setup cannot write to the capture helper's lease, so
// it posts this distributed notification and the app, which holds the
// lease, asks.
//
// It carries nothing and changes no rule: the supervisor asks only while
// remembering is on, and the helper reads that window as it reads any
// other, skipping a never-read app, an excluded app, a private window or a
// password field. The app honours it only after consent and while setup is
// open, so nothing else on this Mac gains a way to ask.

import Foundation

public enum SetupReadRequest {
    /// Onboarding posts the same name (OnboardingKit `SetupReadRequest`).
    public static let notificationName = Notification.Name("ai.hippocampus.setup.readFrontWindow")

    /// Whether to ask the helper for the read: only after consent, and only
    /// while setup, which asked, is open.
    public static func honours(consentGiven: Bool, setupOpen: Bool) -> Bool {
        consentGiven && setupOpen
    }
}
