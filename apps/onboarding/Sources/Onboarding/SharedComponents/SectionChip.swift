import SwiftUI

/// A restrained section label. It carries hierarchy without decorative
/// capsule chrome or altered letter spacing.
struct SectionChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
