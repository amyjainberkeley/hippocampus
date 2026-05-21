import RecallUIKit
import SwiftUI

struct FilterPillsView: View {
    @Binding var filters: FilterState
    let onChanged: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(FilterPill.allCases) { pill in
                pillButton(pill)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func pillButton(_ pill: FilterPill) -> some View {
        let active = filters.isActive(pill)
        return Button {
            filters.toggle(pill)
            onChanged()
        } label: {
            Text(pill.label)
                .font(.system(.caption, design: .default))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(active ? Color.brandMintSubtle : Color.brandBgElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(active ? Color.brandMint : Color.brandCardBorder, lineWidth: 0.5)
                )
                .foregroundStyle(active ? Color.brandMint : Color.brandFgSecondary)
        }
        .buttonStyle(.plain)
    }
}
