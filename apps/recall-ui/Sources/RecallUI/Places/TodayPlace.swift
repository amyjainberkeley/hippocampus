import RecallUIKit
import SwiftUI

/// Overview: one day at a glance (RULINGS W5 to W7, spec-recall S2 as amended
/// by both recall critiques and the insights product critique).
///
/// Top to bottom: the Right now card (today only) with what a connected AI
/// starts with; the day with its date control; the day strip and its
/// legend; the selected session; up to four facts; the day's summary when a
/// model wrote one. Nothing here shows keys, clicks, scrolls or switch counts
/// (RULINGS W4).
///
/// The shell owns the model (it applies routes to it, such as a session row
/// on You) and passes what the place cannot reach itself: the brain reader
/// for screenshots and copies, `open` for a route ("Show in History"), and
/// `search` for a query typed into Ask (a search chip). See
/// `work/contract/places.md`.
struct OverviewPlace: View {
    @ObservedObject var model: OverviewViewModel
    let reader: BrainReader
    let open: (RecallRoute) -> Void
    let search: (String) -> Void

    @State private var hover: StripHover?
    @State private var noticedOpen: Bool
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    init(
        model: OverviewViewModel,
        reader: BrainReader,
        open: @escaping (RecallRoute) -> Void,
        search: @escaping (String) -> Void
    ) {
        self.init(model: model, reader: reader, open: open, search: search, hover: nil, noticedOpen: false)
    }

    /// The renderer draws a hovered session and an open disclosure.
    init(
        model: OverviewViewModel,
        reader: BrainReader,
        open: @escaping (RecallRoute) -> Void,
        search: @escaping (String) -> Void,
        hover: StripHover?,
        noticedOpen: Bool
    ) {
        self.model = model
        self.reader = reader
        self.open = open
        self.search = search
        _hover = State(initialValue: hover)
        _noticedOpen = State(initialValue: noticedOpen)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // The first day's welcome holds the Right now card's place
                // until the first session is saved (first landing, Oct 18).
                if model.showsFirstDay {
                    FirstDayCard(remembering: model.isRemembering, offersConnect: model.offersConnectOnEmptyDay)
                        .transition(.opacity)
                } else if let card = model.rightNow {
                    RightNowCardView(card: card, reader: reader)
                        .transition(.opacity)
                }
                VStack(alignment: .leading, spacing: 18) {
                    dayHeader
                    content
                }
            }
            .animation(MCI.Motion.deliberate, value: model.showsFirstDay)
            .frame(maxWidth: 880, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(MCI.Color.background)
        .task(id: model.day) { await model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) { _ in
            Task { await model.reload() }
        }
    }

    // MARK: The day

    private var dayHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(dayTitle)
                .font(MCI.Font.title2)
                .foregroundStyle(MCI.Color.foreground)
            Spacer()
            HStack(spacing: 2) {
                Button {
                    model.moveDay(-1)
                } label: {
                    Image(systemName: "chevron.left").frame(width: 22, height: 22)
                }
                .help(UserFacingCopy.Overview.previousDay)
                .accessibilityLabel(UserFacingCopy.Overview.previousDay)
                // The title already says "Today" on today.
                if !model.isToday {
                    Button(UserFacingCopy.Overview.today) { model.goToToday() }
                }
                Button {
                    model.moveDay(1)
                } label: {
                    Image(systemName: "chevron.right").frame(width: 22, height: 22)
                }
                .help(UserFacingCopy.Overview.nextDay)
                .accessibilityLabel(UserFacingCopy.Overview.nextDay)
                .disabled(!model.canMoveForward)
            }
            .buttonStyle(.borderless)
            .font(MCI.Font.body)
        }
    }

    private var dayTitle: String {
        if model.isToday { return UserFacingCopy.Overview.today }
        var calendar = model.calendar
        calendar.locale = locale
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).month(.wide).day()
        return model.selectedDate.formatted(style)
    }

    @ViewBuilder
    private var content: some View {
        if let overview = model.overview {
            if model.showsFirstDay {
                firstDay(overview)
            } else if overview.blocks.isEmpty {
                emptyDay(overview)
            } else {
                day(overview)
            }
        } else if model.phase == .unavailable {
            VStack(alignment: .leading, spacing: 10) {
                Text(UserFacingCopy.Overview.dayUnavailable)
                    .font(MCI.Font.body)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                Button(UserFacingCopy.Overview.tryAgain) { Task { await model.reload() } }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 24)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(UserFacingCopy.Overview.loading)
                    .font(MCI.Font.body)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
            }
            .padding(.vertical, 24)
        }
    }

    private func emptyDay(_ overview: DayOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(overview.isToday ? UserFacingCopy.Overview.todayEmpty : UserFacingCopy.Overview.pastDayEmpty)
                .font(MCI.Font.body)
                .foregroundStyle(MCI.Color.foregroundSecondary)
            modelLine(overview)
            // A first day has no Right now card to offer "Connect" yet.
            if model.offersConnectOnEmptyDay {
                OverviewCard {
                    ConnectAIToolsRow()
                }
                .padding(.top, 12)
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The first day's strip, empty, with now marked: the first session
    /// appears there.
    private func firstDay(_ overview: DayOverview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let layout = model.firstDayStrip {
                FirstDayStripView(layout: layout, remembering: model.isRemembering)
            }
            modelLine(overview)
        }
        .padding(.top, 4)
        .transition(.opacity)
    }

    private func day(_ overview: DayOverview) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            // Above the detail, so a hover preview opening downwards is not
            // drawn under it.
            DayStripView(overview: overview, model: model, reader: reader, hover: $hover)
                .padding(.top, 4)
                .zIndex(1)
            if let block = model.selectedBlock {
                SessionDetailView(detail: SessionDetail(block: block, locale: locale, timeZone: timeZone),
                                  reader: reader, open: open, search: search, noticedOpen: $noticedOpen,
                                  showsCardActions: !model.selectedIsRightNow)
            }
            facts(overview)
            if let account = overview.account {
                SummaryDisclosure(account: account)
            }
            modelLine(overview)
        }
    }

    // MARK: Facts

    @ViewBuilder
    private func facts(_ overview: DayOverview) -> some View {
        if !overview.facts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(overview.facts.prefix(4).enumerated()), id: \.offset) { _, fact in
                    let text = fact.text.text(locale: locale, timeZone: timeZone)
                    if let action = fact.action, action.kind != .none {
                        Button {
                            model.perform(fact)
                        } label: {
                            Text(text)
                                .font(MCI.Font.body)
                                .foregroundStyle(MCI.Color.accent)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(text)
                            .font(MCI.Font.body)
                            .foregroundStyle(MCI.Color.foreground)
                            .help(fact.kind == .active ? UserFacingCopy.Overview.activeHelp : "")
                    }
                }
                if model.showsSearches, !overview.searches.isEmpty {
                    HStack(alignment: .top) {
                        SearchChips(queries: overview.searches.map(\.query), search: search)
                        Spacer(minLength: 8)
                        Button(UserFacingCopy.Overview.hide) { model.hideSearches() }
                            .buttonStyle(.borderless)
                            .font(MCI.Font.caption)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func modelLine(_ overview: DayOverview) -> some View {
        if let reason = overview.modelStatus.unavailableReason {
            Text(UserFacingCopy.Overview.modelLine(reason))
                .font(MCI.Font.caption)
                .foregroundStyle(MCI.Color.foregroundMuted)
        }
    }
}

/// The day's summary, behind one disclosure (RULINGS I11).
private struct SummaryDisclosure: View {
    let account: DayAccount
    @State private var isOpen = false

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            VStack(alignment: .leading, spacing: 8) {
                if !account.headline.isEmpty {
                    Text(account.headline)
                        .font(MCI.Font.bodyStrong)
                        .foregroundStyle(MCI.Color.foreground)
                }
                if !account.narrative.isEmpty {
                    Text(account.narrative)
                        .font(MCI.Font.body)
                        .foregroundStyle(MCI.Color.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let caption = UserFacingCopy.writtenOnThisMac(by: account.writtenBy) {
                    Text(caption)
                        .font(MCI.Font.footnote)
                        .foregroundStyle(MCI.Color.foregroundMuted)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(UserFacingCopy.Overview.summaryTitle)
                .font(MCI.Font.body)
                .foregroundStyle(MCI.Color.foreground)
        }
    }
}
