import SwiftUI

/// The Cotypist "Screenshots? … neither stored nor sent anywhere" moment —
/// a calm, prominent callout that answers the one privacy question a capture
/// app must answer, with the load-bearing phrase pulled out in accent-bold.
///
/// Used on the Permissions / capture surface to turn "grant Screen
/// Recording" from a scary ask into a reassurance. `highlight` must be an
/// exact substring of `message`; if it isn't, the whole message renders
/// plainly (no crash, no partial match).
struct ReassuranceBanner: View {
    let systemImage: String
    let message: String
    let highlight: String

    var body: some View {
        HStack(alignment: .top, spacing: OnboardingDesign.Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(OnboardingDesign.Palette.accent)
                .frame(width: 26)

            styledMessage
                .font(.system(size: 15))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(OnboardingDesign.Space.lg)
        .frame(maxWidth: 520)
        .background(
            RoundedRectangle(cornerRadius: OnboardingDesign.Radius.card, style: .continuous)
                .fill(OnboardingDesign.Palette.accentSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingDesign.Radius.card, style: .continuous)
                .stroke(OnboardingDesign.Palette.accentHairline, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }

    /// Renders `message` with `highlight` emphasized. Splits on the first
    /// occurrence of the substring; falls back to the plain string when the
    /// highlight isn't found. Uses `Text.foregroundColor` (which reliably
    /// returns `Text`, unlike the view-level `foregroundStyle`) so the
    /// `Text + Text` concatenation typechecks.
    private var styledMessage: Text {
        guard let range = message.range(of: highlight) else {
            return Text(message)
        }
        let before = String(message[message.startIndex..<range.lowerBound])
        let mid = String(message[range])
        let after = String(message[range.upperBound...])
        return Text(before)
            + Text(mid)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(OnboardingDesign.Palette.accent)
            + Text(after)
    }
}
