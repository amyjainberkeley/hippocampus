import AppKit
import RecallUIKit
import SwiftUI

/// ⌘↩ in the field: Ask {Tool} with the question and its top matches, as a
/// press on a button of its own. A new sequence is a new press.
struct FieldAsk: Equatable {
    let source: AskAISource
    let sequence: Int
}

/// The alert as macOS draws it, for pictures, which can't capture an
/// alert's window: the app's icon, the title, the words, then Forget and the
/// default Cancel.
struct ForgetAlertFacsimile: View {
    let confirmation: ForgetConfirmation

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(confirmation.title)
                .font(.system(size: 13, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(MCI.Color.foreground)
            Text(confirmation.message)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(MCI.Color.foreground)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(NavigationCopy.forgetAction)
                    .foregroundStyle(MCI.Color.error)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(MCI.Color.surfaceElevated))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(MCI.Color.border, lineWidth: 0.5))
                Text(NavigationCopy.cancelAction)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(MCI.Color.accentFill))
            }
            .font(.system(size: 13))
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 260)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MCI.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MCI.Color.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 10)
    }
}

extension WindowStatus {
    /// Why Today can't say "Now" (SPEC 3.1): remembering is paused, off or
    /// not running, or a permission is off. Nil while it remembers.
    var todayStop: TodayStop? {
        switch kind {
        case .needsPermission: .needsPermission
        case .paused, .off, .notSetUp, .notRunning, .couldNotTurnOn: .paused
        case let .byHand(remembering): remembering ? nil : .paused
        case .remembering, .starting, .nothingSaved, .skipping, .forgetting, .finishingForget, .notSaving,
             .couldNotStop, .demoMemory:
            nil
        }
    }
}
