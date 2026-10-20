// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import HippocampusKit

/// The status row at the top of Preferences, Remembering: the menu's picture,
/// title, line and button, so the menu, Ask's footer and Preferences say one
/// thing (product critique 11).
struct CaptureHealthView: View {
    @ObservedObject var supervisor: ProcessSupervisor
    let perform: (CaptureStatusAction) -> Void

    var body: some View {
        let status = supervisor.menuBarStatus
        // The menu's own row: a timed pause says when it ends, and a
        // forget's hold says "Forgetting…" (SPEC 2.6.2, 3.11).
        let row = supervisor.menuRow()
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: MenuBarStatusIcon.image(for: status))
                .renderingMode(.template)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.headline)
                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action = row.action {
                    Button(row.actionTitle ?? action.title) { perform(action) }
                        .padding(.top, 2)
                }
            }
        }
        .task { supervisor.refreshCaptureStatus() }
    }
}
