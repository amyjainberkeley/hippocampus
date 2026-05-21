import SwiftUI
import OnboardingKit

struct DoneStepView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("You're Set")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Hippocampus is running. Look for the menu-bar icon.")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                shortcutRow(keys: "\u{21E7}\u{2318}P", label: "Pause capture instantly")
                shortcutRow(keys: "\u{21E7}\u{2318}F", label: "Search what you've seen")
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 360)
        }
    }

    private func shortcutRow(keys: String, label: String) -> some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.body)
        }
    }
}
