import AppKit
import RecallUIKit
import SwiftUI

/// Ask {Tool} without a button of its own: the field's ⌘↩ (the question
/// and its top matches), or a row's Ask Claude ▸ (the moments, and the tool
/// it named). The shell presses a hidden button; a new sequence is a new
/// press.
struct FieldAsk: Equatable {
    let source: AskAISource
    var tool: AskTool?
    let sequence: Int
}

/// The alert as macOS draws it, for pictures, which can't capture an
/// alert's window: the app's icon, the title, the words, then Forget and the
/// default Cancel.
struct ForgetAlertFacsimile: View {
    let confirmation: ForgetConfirmation

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: Self.icon)
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

    /// The app's icon, as the alert shows it. The bare renderer has none of
    /// its own, so its pictures take the icon the app is built with.
    private static var icon: NSImage {
        #if DEBUG
        if Bundle.main.bundleURL.pathExtension != "app",
           let built = NSImage(contentsOf: URL(fileURLWithPath: #filePath)
               .deletingLastPathComponent() // Forget
               .deletingLastPathComponent() // RecallUI
               .deletingLastPathComponent() // Sources
               .deletingLastPathComponent() // recall-ui
               .deletingLastPathComponent() // apps
               .deletingLastPathComponent() // the repository
               .appendingPathComponent("assets/branding/AppIcon.icns")) {
            return built
        }
        #endif
        return NSApplication.shared.applicationIconImage
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
