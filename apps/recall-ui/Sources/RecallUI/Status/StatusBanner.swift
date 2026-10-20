import RecallUIKit
import SwiftUI

/// One line under the field on every page whenever remembering isn't on
/// (SPEC 2.6.3): what is true, and the one button that changes it. It has no
/// close button; it goes when remembering comes back. It is the only thing in
/// the window that interrupts.
struct StatusBanner: View {
    let banner: WindowStatus.Banner
    let perform: (WindowStatus.Action) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if banner.isProblem {
                Circle()
                    .fill(MCI.Color.error)
                    .frame(width: 7, height: 7)
                    .padding(.horizontal, 5)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "pause.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .accessibilityHidden(true)
            }
            Text(verbatim: banner.text)
                .font(.system(size: 13))
                .foregroundStyle(MCI.Color.foreground)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: MCI.Spacing.m)
            Button(banner.action.title) { perform(banner.action) }
                .controlSize(.regular)
        }
        .padding(.leading, 22)
        .padding(.trailing, 20)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MCI.Color.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MCI.Color.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            // Announced once when it appears; its button is reachable by Tab.
            AccessibilityNotification.Announcement(banner.text).post()
        }
    }
}
