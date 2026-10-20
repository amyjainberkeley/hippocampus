import AppKit
import RecallUIKit
import SwiftUI

/// A forget a page asked for that needs a yes first (SPEC 3.11): more than
/// 20 picked moments, a session, an hour, a page or a search. Its words, the
/// line said the first time anyone forgets, and what it removes, by ids and
/// times only.
struct ForgetConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    /// "Forgetting removes it from this Mac. What you already sent to an AI
    /// tool stays in that tool." The first time only.
    let firstForget: Bool
    let request: ForgetRequest
    /// The audit log's line once it's done.
    let audit: ForgetAudit

    /// What the alert says under its title.
    var message: String {
        firstForget ? body + "\n\n" + NavigationCopy.firstForget : body
    }
}

/// The audit log's line for a forget (SPEC 3.9's Activity): what kind of
/// forget it was and how many moments went, never content.
enum ForgetAudit: Equatable, Sendable {
    /// Picked moments, a page's or a search's.
    case moments(Int)
    /// A span of time: a session, an hour, the last 24 hours.
    case span(ForgetRequest.Span)
    /// Forget Recent's choice.
    case recent(ForgetRecentChoice)

    /// The details the Activity list reads: `count`, and for recent time
    /// `range_minutes`, `range_hours` or `range: today`.
    func details(count: UInt64, now: Date) -> (action: AuditAction, details: [String: String]) {
        switch self {
        case .moments:
            return (.deleteEvent, ["count": "\(count)"])
        case let .recent(choice):
            var details = ["count": "\(count)"]
            switch choice {
            case .tenMinutes: details["range_minutes"] = "10"
            case .hour: details["range_minutes"] = "60"
            case .today: details["range"] = "today"
            }
            return (.deleteEventsInRange, details)
        case let .span(span):
            var details = ["count": "\(count)"]
            // The last 24 hours, up to the click: Privacy's own forget.
            let nowUs = UInt64(max(0, now.timeIntervalSince1970 * 1_000_000))
            let length = span.endUs >= span.startUs ? span.endUs - span.startUs : 0
            let hour: UInt64 = 3_600_000_000
            if nowUs >= span.endUs, nowUs - span.endUs < 5 * 60_000_000,
               length > 24 * hour - 5 * 60_000_000, length <= 24 * hour + 5 * 60_000_000 {
                details["range_hours"] = "24"
            }
            return (.deleteEventsInRange, details)
        }
    }

    /// Writes the line. Only after a forget that deleted something real:
    /// the preview and pictures never get this far.
    func record(count: UInt64, now: Date, log: AuditLog = .shared) {
        let line = details(count: count, now: now)
        log.record(action: line.action, details: line.details)
    }
}

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
             .couldNotStop:
            nil
        }
    }
}
