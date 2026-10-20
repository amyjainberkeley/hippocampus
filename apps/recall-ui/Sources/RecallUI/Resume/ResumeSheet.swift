import RecallUIKit
import SwiftUI

/// Resume: what was open in a Working On item's last session, with a
/// checkbox each (SPEC-DELTA 3). Nothing opens until the click; ⌘↩ is the
/// default button. Resume sends nothing anywhere.
///
/// A seam for now: plans aren't read yet, so it says there is nothing to
/// reopen. Reading the plan, the checkboxes' rules and opening what is
/// ticked land with Resume.
struct ResumeSheet: View {
    let itemId: String
    var planner: any ResumePlanning = NoResumePlans()

    @Environment(\.dismiss) private var dismiss
    @State private var plan: ResumePlan?

    var body: some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.l) {
            Text(WorkCopy.resumeTitle)
                .mciFont(.title2)
                .foregroundStyle(MCI.Color.foreground)
            if let plan {
                if plan.items.isEmpty {
                    Text(WorkCopy.resumeNothing)
                        .mciFont(.body)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                } else {
                    ForEach(plan.items) { target in
                        Text(verbatim: target.title)
                            .mciFont(.body)
                            .foregroundStyle(target.note == nil ? MCI.Color.foreground : MCI.Color.foregroundSecondary)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: MCI.Spacing.s) {
                Spacer(minLength: 0)
                Button(WorkCopy.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(WorkCopy.resume) { dismiss() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(plan?.openable.isEmpty ?? true)
            }
        }
        .padding(MCI.Spacing.xl)
        .frame(width: 420, alignment: .leading)
        .task(id: itemId) {
            plan = (try? await planner.plan(item: itemId)) ?? .empty
        }
    }
}

/// Resume, the primary button on a Working On page, Today's card and an
/// answer about an item: it opens the sheet, which opens nothing by itself.
struct ResumeButton: View {
    let itemId: String
    let open: (RecallRoute) -> Void

    var body: some View {
        Button(WorkCopy.resume) { open(.resume(item: itemId)) }
            .buttonStyle(.borderedProminent)
    }
}

/// Which item's Resume sheet is open: what the window presents the sheet
/// with when a route asks for it (`RecallRoute.resume(item:)`).
struct ResumeSheetItem: Identifiable, Equatable {
    /// The item's id.
    let id: String
}
