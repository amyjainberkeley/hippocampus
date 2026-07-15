import SwiftUI

/// One privacy promise: a glyph, a short title, and a one-line "what it
/// means." Three of these make the Raycast "Full control · No collection ·
/// Encrypted & secure" assurance strip.
struct AssuranceItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String

    init(icon: String, title: String, detail: String) {
        self.icon = icon
        self.title = title
        self.detail = detail
    }
}

/// The compact assurance strip shown inline under a trust-sensitive control
/// (e.g. "Enable capture"). Reads as three short promises; a trailing info
/// button opens a popover with the full rationale and an "Open Privacy
/// Statement" affordance — mirroring Raycast's "Ask anything" enable card.
struct AssuranceRow: View {
    let items: [AssuranceItem]
    /// Fired when the user taps "Open Privacy Statement" in the popover.
    var onOpenPrivacyStatement: (() -> Void)?

    @State private var showDetails = false
    @Environment(\.colorSchemeContrast) private var contrast

    /// Border bumped so the strip's edge stays visible under Increase
    /// Contrast (the 0.10 hairline can otherwise vanish) — mirrors GlassCard.
    private var borderColor: Color {
        contrast == .increased ? Color.primary.opacity(0.3) : OnboardingDesign.Palette.hairline
    }

    var body: some View {
        HStack(spacing: OnboardingDesign.Space.md) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Text("·")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 5) {
                    Image(systemName: item.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OnboardingDesign.Palette.accent)
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                showDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("What these mean")
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                AssurancePopover(items: items, onOpenPrivacyStatement: onOpenPrivacyStatement)
            }
        }
        .padding(.horizontal, OnboardingDesign.Space.md)
        .padding(.vertical, OnboardingDesign.Space.sm)
        .background(
            Capsule().fill(OnboardingDesign.Palette.cardFill)
        )
        .overlay(
            Capsule().stroke(borderColor, lineWidth: contrast == .increased ? 1.5 : 1)
        )
        .accessibilityElement(children: .combine)
    }
}

/// The expanded assurance detail — three icon + title + subtitle rows and an
/// "Open Privacy Statement" button. Matches the Raycast enable-AI popover.
struct AssurancePopover: View {
    let items: [AssuranceItem]
    var onOpenPrivacyStatement: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.lg) {
            Text("Enabling capture is always on your terms:")
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(items) { item in
                HStack(alignment: .top, spacing: OnboardingDesign.Space.md) {
                    Image(systemName: item.icon)
                        .font(.system(size: 15))
                        .foregroundStyle(OnboardingDesign.Palette.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(item.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let onOpenPrivacyStatement {
                Divider()
                Button {
                    onOpenPrivacyStatement()
                } label: {
                    Label("Open Privacy Statement", systemImage: "person.text.rectangle")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(OnboardingDesign.Palette.accent)
            }
        }
        .padding(OnboardingDesign.Space.xl)
        .frame(width: 340)
    }
}
