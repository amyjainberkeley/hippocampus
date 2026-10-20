import RecallUIKit
import SwiftUI

/// History: the day's moments under the field while it is empty, with the day
/// moving back and forth (RULINGS W8).
struct HistoryView: View {
    @ObservedObject var history: TimelineViewModel
    let reader: BrainReader
    var calendar: Calendar = .current
    var now: @Sendable () -> Date = { Date() }

    private var today: MemoryDay { MemoryDay(date: now(), calendar: calendar) }
    private var day: MemoryDay { history.day ?? today }
    private var isToday: Bool { day == today }

    private var dayDate: Date {
        Date(timeIntervalSince1970: Double(day.startUs) / 1_000_000)
    }

    private var dayTitle: String {
        if isToday { return UserFacingCopy.todayAction }
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        return dayDate.formatted(style)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: MCI.Spacing.s) {
                Button { move(by: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help(UserFacingCopy.previousDay)
                    .accessibilityLabel(UserFacingCopy.previousDay)
                Text(verbatim: dayTitle)
                    .mciFont(.bodyStrong)
                    .foregroundStyle(Color.brandFgPrimary)
                Button { move(by: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(isToday)
                    .help(UserFacingCopy.nextDay)
                    .accessibilityLabel(UserFacingCopy.nextDay)
                Spacer(minLength: 0)
                if history.range != nil {
                    Button(UserFacingCopy.wholeDayAction) { Task { await history.showWholeDay() } }
                        .buttonStyle(.borderless)
                }
                if !isToday {
                    Button(UserFacingCopy.todayAction) { Task { await history.show(day: today) } }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, MCI.Spacing.xl)
            .padding(.vertical, MCI.Spacing.s)
            Divider()
            TimelineView(viewModel: history, reader: reader, isToday: isToday, calendar: calendar)
        }
    }

    private func move(by days: Int) {
        guard let date = calendar.date(byAdding: .day, value: days, to: dayDate) else { return }
        let target = MemoryDay(date: date, calendar: calendar)
        guard target.startUs <= today.startUs else { return }
        Task { await history.show(day: target) }
    }
}
