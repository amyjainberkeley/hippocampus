import RecallUIKit
import SwiftUI

/// "Forget recent memory?" (SPEC 3.11): the last 10 minutes, the last hour
/// or today, from the status menu, ⇧⌘⌫, Privacy's Forget Recent… and a
/// `forget=` link. Cancel is the default; Return never forgets. Today asks
/// for the typed word FORGET. The time range is fixed at the click.
struct ForgetRecentSheet: View {
    @State var choice: ForgetRecentChoice
    /// When the sheet opened: what each choice means is fixed from here.
    let now: Date
    var calendar: Calendar = .current
    /// The line said the first time anyone forgets.
    var saysFirstForget = false
    let forget: (ForgetRecentChoice) -> Void
    let cancel: () -> Void

    @State private var typed = ""
    @Environment(\.locale) private var locale

    private var canForget: Bool {
        !choice.needsTypedWord || typed.trimmingCharacters(in: .whitespaces) == NavigationCopy.forgetWord
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.l) {
            Text(NavigationCopy.forgetRecentTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(MCI.Color.foreground)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(ForgetRecentChoice.allCases, id: \.self) { option in
                    Button {
                        choice = option
                    } label: {
                        HStack(spacing: 0) {
                            RadioMark(on: choice == option)
                                .padding(.trailing, 8)
                            Text(title(option))
                                .font(.system(size: 13))
                                .foregroundStyle(MCI.Color.foreground)
                                .frame(width: 168, alignment: .leading)
                            Text(since(option))
                                .font(.system(size: 13))
                                .foregroundStyle(MCI.Color.foregroundSecondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title(option)), \(since(option))")
                    .accessibilityAddTraits(choice == option ? [.isSelected, .isButton] : .isButton)
                }
            }
            Text(NavigationCopy.forgetRecentBody)
                .font(.system(size: 13))
                .foregroundStyle(MCI.Color.foregroundSecondary)
            if choice.needsTypedWord {
                TextField(NavigationCopy.typeForget, text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(NavigationCopy.typeForget)
            }
            if saysFirstForget {
                Text(NavigationCopy.firstForget)
                    .font(.system(size: 12))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: MCI.Spacing.s) {
                Spacer(minLength: 0)
                Button {
                    forget(choice)
                } label: {
                    Text(NavigationCopy.forgetAction)
                        .foregroundStyle(canForget ? MCI.Color.error : MCI.Color.foregroundMuted)
                }
                .disabled(!canForget)
                Button(NavigationCopy.cancelAction, action: cancel)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(width: 440)
        .background(MCI.Color.surface)
        .onExitCommand(perform: cancel)
    }

    private func title(_ choice: ForgetRecentChoice) -> String {
        switch choice {
        case .tenMinutes: NavigationCopy.lastTenMinutes
        case .hour: NavigationCopy.lastHour
        case .today: NavigationCopy.todayChoice
        }
    }

    private func since(_ choice: ForgetRecentChoice) -> String {
        guard choice != .today else { return NavigationCopy.sinceMidnight }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return NavigationCopy.since(formatter.string(from: choice.start(at: now, calendar: calendar)))
    }
}

/// A radio button's circle.
private struct RadioMark: View {
    let on: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(on ? MCI.Color.accentFill : MCI.Color.surface)
            Circle()
                .strokeBorder(on ? Color.clear : MCI.Color.borderStrong, lineWidth: 1)
            if on {
                Circle().fill(Color.white).frame(width: 6, height: 6)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}
