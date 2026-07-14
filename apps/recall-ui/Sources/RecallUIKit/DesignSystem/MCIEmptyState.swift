// MCIEmptyState.swift — cycle 8.49 polished empty-state component.
//
// Product-readiness audit gap fix (cycle 8.44 →
// `docs/research/2026-07-13-product-readiness-audit.md` "Top-5 polish
// gaps" — Missing empty states). Before this file, empty states across
// the recall UI were a scatter of raw `ContentUnavailableView`
// instantiations with mixed copy tone, mixed icon choices, and no
// unified action-button treatment. When the brain is fresh, when a
// search returns 0 hits, when a filter combo is too narrow, when a
// related-hits flyout has no siblings — users saw either apologetic
// dead-ends or unstyled placeholders. This component gives every empty
// state one home: informative, welcoming, action-oriented, on the
// Stripe / Raycast baseline.
//
// # Design language
//
// Structure (top-to-bottom):
//   - Large muted SF Symbol icon (56pt, `foregroundMuted`)
//   - Heading (`MCIFontRole.title2`, `foreground`)
//   - Body copy (`MCIFontRole.body`, `foregroundSecondary`)
//   - Optional bordered action button (`accent`-tinted)
//
// Spacing: 24pt (MCI.Spacing.xl) between rows; 48pt (MCI.Spacing.xxxl)
// outer vertical padding so the block breathes on any pane size.
//
// Accessibility: the whole block is one accessibility element with a
// combined label so VoiceOver reads "heading, body, action" as a
// single unit. The button, when present, remains individually
// focusable via `.accessibilityAddTraits(.isButton)`.
//
// # Usage
//
// Every named factory below is a canonical MCI empty-state string
// approved for user-facing copy (see `docs/copy/empty-states.md` when it
// lands — for now this file IS the source of truth).
//
//     MCIEmptyState.freshBrain()
//     MCIEmptyState.noSearchHits(query: viewModel.query)
//     MCIEmptyState.filterTooNarrow { viewModel.clear() }
//     MCIEmptyState.noRelatedHits()
//     MCIEmptyState.noPrivacyMoments()
//     MCIEmptyState.noPrivacyEvents(hasActiveFilter: filter.isActive)
//     MCIEmptyState.noEpisodes()
//     MCIEmptyState.noTimelineEvents()
//     MCIEmptyState.staleEvent(onBack: { … })
//
// Copy is reassuring + action-oriented (never apologetic).

import SwiftUI

// MARK: - View

/// The one-and-only empty-state view for MCI's recall surfaces. Composes
/// an SF Symbol icon + heading + body + optional action button on the
/// MCIDesignSystem token grid. Pure — no dependencies on view models,
/// no side effects; the caller wires the button action.
public struct MCIEmptyState: View {
    public let icon: String
    public let title: String
    public let message: String
    public let actionTitle: String?
    public let action: (() -> Void)?

    /// Full initializer. Prefer the named static factories below for
    /// canonical MCI copy; use this only for one-off empty states not
    /// yet promoted to the factory list.
    public init(
        icon: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: MCI.Spacing.xl) {
            Image(systemName: icon)
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(MCI.Color.foregroundMuted)
                .accessibilityHidden(true)

            VStack(spacing: MCI.Spacing.s) {
                Text(title)
                    .mciFont(.title2)
                    .foregroundStyle(MCI.Color.foreground)
                    .multilineTextAlignment(.center)

                Text(message)
                    .mciFont(.body)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 360)

            if let actionTitle, let action {
                Button(actionTitle) { action() }
                    .buttonStyle(.bordered)
                    .tint(MCI.Color.accent)
                    .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.vertical, MCI.Spacing.xxxl)
        .padding(.horizontal, MCI.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}

// MARK: - Canonical factories

public extension MCIEmptyState {
    /// Fresh brain / cold start — 0 events captured. Warm, patient,
    /// tells the user MCI is actively working in the background.
    static func freshBrain() -> MCIEmptyState {
        MCIEmptyState(
            icon: "brain.head.profile",
            title: "Hippocampus is warming up",
            message: "Keep using your Mac normally — captures start "
                + "appearing as MCI observes your workflow. Come back "
                + "in a few hours for your first recall."
        )
    }

    /// Search returned 0 hits for a non-empty query. Includes the query
    /// verbatim so the user sees what MCI searched for; nudges toward
    /// broader terms + the custom-names dictionary.
    static func noSearchHits(query: String) -> MCIEmptyState {
        MCIEmptyState(
            icon: "sparkle.magnifyingglass",
            title: "No memories match \u{201C}\(query)\u{201D}",
            message: "Try broader terms, check spelling, or add "
                + "custom names in Settings so MCI recognizes your "
                + "shorthand."
        )
    }

    /// Filter combination is too narrow — 0 results with active
    /// filters. Offers a "Clear filters" action.
    static func filterTooNarrow(onClear: @escaping () -> Void) -> MCIEmptyState {
        MCIEmptyState(
            icon: "line.3.horizontal.decrease.circle",
            title: "No memories match these filters",
            message: "Try clearing a filter to broaden the search.",
            actionTitle: "Clear filters",
            action: onClear
        )
    }

    /// Detail pane opened against an event that no longer exists (deleted
    /// in another window / session). Reassuring + a "Back" action.
    static func staleEvent(onBack: @escaping () -> Void) -> MCIEmptyState {
        MCIEmptyState(
            icon: "tray",
            title: "This memory is no longer available",
            message: "It may have been deleted, or marked private. "
                + "Everything else is intact.",
            actionTitle: "Back to search",
            action: onBack
        )
    }

    /// PrivacyDashboard event list empty — either the brain is fresh
    /// or the user deleted everything. Distinguishes the "filter is
    /// hiding results" case so the copy stays honest.
    static func noPrivacyEvents(hasActiveFilter: Bool) -> MCIEmptyState {
        if hasActiveFilter {
            return MCIEmptyState(
                icon: "line.3.horizontal.decrease.circle",
                title: "Nothing in the current filter",
                message: "Widen the app or time filter above to see "
                    + "captured events."
            )
        }
        // Cycle 8.54 copy audit — "brain" → "memory". Same referent;
        // matches the user-facing product noun the landing page uses.
        return MCIEmptyState(
            icon: "lock.shield",
            title: "Your memory is empty",
            message: "Everything Hippocampus captures stays here, on "
                + "this Mac, encrypted end-to-end. You are always in "
                + "control."
        )
    }

    /// RelatedHitsFlyout — the source hit has no cross-app siblings.
    /// Tone: this is a normal state, not a failure.
    static func noRelatedHits() -> MCIEmptyState {
        MCIEmptyState(
            icon: "link",
            title: "No cross-app connections yet",
            message: "Related memories appear here as MCI links "
                + "events across your apps."
        )
    }

    /// Privacy Moments tab — no redactions recorded yet. This is a
    /// GOOD signal: MCI hasn't needed to redact anything.
    static func noPrivacyMoments() -> MCIEmptyState {
        MCIEmptyState(
            icon: "eye.slash",
            title: "No privacy moments yet",
            message: "MCI redacts sensitive captures automatically. "
                + "When it does, you\u{2019}ll see the record here."
        )
    }

    /// Episodes tab — no episode segments yet (needs a few minutes of
    /// same-app activity to form one).
    static func noEpisodes() -> MCIEmptyState {
        MCIEmptyState(
            icon: "rectangle.stack",
            title: "No episodes yet",
            message: "Episodes group a few minutes of continuous work "
                + "in one app. Keep using your Mac — they\u{2019}ll "
                + "appear soon."
        )
    }

    /// Timeline tab — no events captured yet (fresh brain).
    static func noTimelineEvents() -> MCIEmptyState {
        MCIEmptyState(
            icon: "clock",
            title: "No events yet",
            message: "Start using your Mac normally. Hippocampus is "
                + "recording in the background and events will appear "
                + "here as they\u{2019}re captured."
        )
    }
}

// MARK: - Previews

#Preview("Fresh brain") {
    MCIEmptyState.freshBrain()
        .frame(width: 480, height: 400)
        .background(MCI.Color.background)
}

#Preview("No search hits") {
    MCIEmptyState.noSearchHits(query: "vector databases")
        .frame(width: 480, height: 400)
        .background(MCI.Color.background)
}

#Preview("Filter too narrow") {
    MCIEmptyState.filterTooNarrow(onClear: {})
        .frame(width: 480, height: 400)
        .background(MCI.Color.background)
}

#Preview("Stale event") {
    MCIEmptyState.staleEvent(onBack: {})
        .frame(width: 480, height: 400)
        .background(MCI.Color.background)
}

#Preview("Privacy events — fresh") {
    MCIEmptyState.noPrivacyEvents(hasActiveFilter: false)
        .frame(width: 480, height: 400)
        .background(MCI.Color.background)
}

#Preview("Privacy events — filter active") {
    MCIEmptyState.noPrivacyEvents(hasActiveFilter: true)
        .frame(width: 480, height: 400)
        .background(MCI.Color.background)
}

#Preview("No related hits") {
    MCIEmptyState.noRelatedHits()
        .frame(width: 320, height: 240)
        .background(MCI.Color.background)
}

#Preview("No privacy moments") {
    MCIEmptyState.noPrivacyMoments()
        .frame(width: 480, height: 400)
        .background(MCI.Color.background)
}

#Preview("No episodes") {
    MCIEmptyState.noEpisodes()
        .frame(width: 480, height: 400)
        .background(MCI.Color.background)
}

#Preview("No timeline events") {
    MCIEmptyState.noTimelineEvents()
        .frame(width: 480, height: 400)
        .background(MCI.Color.background)
}
