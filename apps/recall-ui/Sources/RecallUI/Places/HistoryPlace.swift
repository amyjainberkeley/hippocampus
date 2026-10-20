import RecallUIKit
import SwiftUI

/// History (⌘2): the day's moments, newest first, with the day moving back
/// and forth (RULINGS W8, SPEC 3.4). "‹ Today ›" names the day; on another
/// day a Today button comes back to it, and a session's own time opened
/// from Today widens to its Whole Day.
struct HistoryView: View {
    @ObservedObject var history: TimelineViewModel
    let reader: BrainReader
    var calendar: Calendar = .current
    var now: @Sendable () -> Date = { Date() }
    /// Working On's read, for "Part of …" under a moment's header.
    var work: (any WorkReader)? = nil
    /// Opens a Working On item from "Part of …".
    var open: (RecallRoute) -> Void = { _ in }
    /// How long moments are kept, for the line at the oldest day.
    var retention: @Sendable () -> RetentionSetting? = { RetentionSetting.read(from: RetentionSetting.defaultURL) }

    @Environment(\.locale) private var locale

    private var today: MemoryDay { MemoryDay(date: now(), calendar: calendar) }
    private var day: MemoryDay { history.day ?? today }
    private var isToday: Bool { day == today }

    private var dayDate: Date {
        Date(timeIntervalSince1970: Double(day.startUs) / 1_000_000)
    }

    /// "Today", "Yesterday", or the day itself: "Friday, Oct 9".
    private var dayTitle: String {
        if isToday { return LibraryCopy.History.today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: Date(timeIntervalSince1970:
            Double(today.startUs) / 1_000_000)), MemoryDay(date: yesterday, calendar: calendar) == day {
            return UserFacingCopy.Overview.yesterday
        }
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        style.locale = locale
        return dayDate.formatted(style)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: MCI.Spacing.s) {
                Button { move(by: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help(LibraryCopy.History.previousDay)
                    .accessibilityLabel(LibraryCopy.History.previousDay)
                Text(verbatim: dayTitle)
                    .mciFont(.bodyStrong)
                    .foregroundStyle(Color.brandFgPrimary)
                    .accessibilityAddTraits(.isHeader)
                Button { move(by: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(isToday)
                    .help(LibraryCopy.History.nextDay)
                    .accessibilityLabel(LibraryCopy.History.nextDay)
                Spacer(minLength: 0)
                if history.range != nil {
                    Button(LibraryCopy.History.wholeDay) { Task { await history.showWholeDay() } }
                        .buttonStyle(.borderless)
                }
                if !isToday {
                    Button(LibraryCopy.History.today) { Task { await history.show(day: today) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, MCI.Spacing.xl)
            .padding(.vertical, MCI.Spacing.s)
            Divider()
            TimelineView(viewModel: history, reader: reader, isToday: isToday, calendar: calendar,
                         work: work, open: open, retention: retention)
        }
    }

    private func move(by days: Int) {
        guard let date = calendar.date(byAdding: .day, value: days, to: dayDate) else { return }
        let target = MemoryDay(date: date, calendar: calendar)
        guard target.startUs <= today.startUs else { return }
        Task { await history.show(day: target) }
    }
}

/// History's place, as the sidebar names it.
typealias HistoryPlace = HistoryView
