import RecallUIKit
import SwiftUI

/// Today (SPEC 3.1): "where was I?", then "what did today look like?"
///
/// Top to bottom: the title with the day control; the card (where you are
/// now, or where you left off), with "Also from yesterday" under it on a
/// morning; Your day: the strip with today's calendar over it and the legend
/// in the sidebar's words, then the selected session; what you looked up
/// today; the day's summary when a model wrote one. The first day keeps the
/// card's place with its welcome. Nothing here shows keys, clicks, scrolls
/// or switch counts (RULINGS W4).
///
/// The shell owns the model (it applies routes to it) and passes what the
/// place cannot reach itself: the brain reader for screenshots and copies,
/// `open` for a route ("Show in History", an item, Resume), and `search`
/// for a query (a search chip). The field and the banner sit above the
/// page, in the shell.
struct TodayPlace: View {
    @ObservedObject var model: OverviewViewModel
    let reader: BrainReader
    let open: (RecallRoute) -> Void
    let search: (String) -> Void
    /// Opens Looked Up, on a search or on all of them; nil shows no "All ›",
    /// and a search chip searches with `search`.
    var lookedUp: ((String?) -> Void)? = nil
    /// A line the shell shows once under the title (the new sidebar's
    /// one-time line, SPEC 2.12), with its own button.
    var notice: AnyView? = nil

    @State private var hover: StripHover?
    @State private var noticedOpen: Bool
    @State private var summaryOpen: Bool
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.todayStop) private var stop
    @Environment(\.showCalendar) private var showCalendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The content's widest, as the prototype's page: 900 pt with its margins.
    static let maxWidth: CGFloat = 836

    init(
        model: OverviewViewModel,
        reader: BrainReader,
        open: @escaping (RecallRoute) -> Void,
        search: @escaping (String) -> Void,
        lookedUp: ((String?) -> Void)? = nil,
        notice: AnyView? = nil
    ) {
        self.init(model: model, reader: reader, open: open, search: search, lookedUp: lookedUp, notice: notice,
                  hover: nil, noticedOpen: false, summaryOpen: false)
    }

    /// The renderer draws a hovered session and open disclosures.
    init(
        model: OverviewViewModel,
        reader: BrainReader,
        open: @escaping (RecallRoute) -> Void,
        search: @escaping (String) -> Void,
        lookedUp: ((String?) -> Void)? = nil,
        notice: AnyView? = nil,
        hover: StripHover?,
        noticedOpen: Bool,
        summaryOpen: Bool = false
    ) {
        self.model = model
        self.reader = reader
        self.open = open
        self.search = search
        self.lookedUp = lookedUp
        self.notice = notice
        _hover = State(initialValue: hover)
        _noticedOpen = State(initialValue: noticedOpen)
        _summaryOpen = State(initialValue: summaryOpen)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let notice {
                    notice
                        .padding(.top, -12)
                }
                // The first day's welcome holds the card's place until the
                // first session is saved (first landing, Oct 18).
                if model.showsFirstDay {
                    FirstDayCard(remembering: model.isRemembering, stopped: stop,
                                 offersConnect: model.offersConnectOnEmptyDay,
                                 offersCalendar: model.showsCalendarOffer,
                                 savedSoFar: model.savedSoFar, newest: model.newestMoment,
                                 showCalendar: takeCalendarOffer, open: open)
                        .transition(.opacity)
                } else if let card = model.rightNow {
                    VStack(alignment: .leading, spacing: 14) {
                        TodayCardView(card: card, model: model, reader: reader, open: open)
                        if let also = model.alsoFrom(locale: locale) {
                            AlsoFromLine(day: also.day, items: also.items, open: open)
                        }
                    }
                    .transition(.opacity)
                }
                // The calendar, offered once (SPEC-DELTA 5): the first day's
                // card makes the offer itself.
                if model.showsCalendarOffer, !model.showsFirstDay {
                    CalendarOfferLine(show: takeCalendarOffer, notNow: { model.calendarOffered() })
                        .transition(.opacity)
                }
                yourDay
                lookedUpToday
                summary
            }
            .animation(reduceMotion ? MCI.Motion.snap : MCI.Motion.deliberate, value: model.showsFirstDay)
            .animation(MCI.Motion.standard, value: model.showsCalendarOffer)
            .frame(maxWidth: Self.maxWidth, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .background(MCI.Color.background)
        .task(id: model.day) { await model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) { _ in
            Task { await model.reload() }
        }
    }

    /// A search chip: Looked Up on that search, else the field searches it.
    /// The page opens on the search the chip leaves for it (SPEC 3.1, 3.6).
    private func openSearch(_ query: String) {
        guard let lookedUp else { return search(query) }
        LookedUpFocus.shared.open(on: query)
        lookedUp(query)
    }

    /// "All ›": Looked Up on its list.
    private func openLookedUp() {
        LookedUpFocus.shared.open(on: nil)
        lookedUp?(nil)
    }

    private func takeCalendarOffer() {
        model.calendarOffered()
        if let showCalendar {
            showCalendar()
        } else {
            Task { _ = await WorkspacePreferencesRouter.shared.open(.general, bundleURL: Bundle.main.bundleURL) }
        }
    }

    // MARK: The title and the day

    private var header: some View {
        HStack(alignment: .center) {
            Text(dayTitle)
                .font(MCI.Font.title)
                .foregroundStyle(MCI.Color.foreground)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            HStack(spacing: 2) {
                Button {
                    model.moveDay(-1)
                } label: {
                    Image(systemName: "chevron.left").frame(width: 26, height: 24)
                }
                .help(UserFacingCopy.Overview.previousDay)
                .accessibilityLabel(UserFacingCopy.Overview.previousDay)
                .disabled(model.showsFirstDay)
                // The colour the row sets would keep a disabled arrow at full
                // strength: dimmed as the window's own ‹ › are.
                .opacity(model.previousDayArrowOpacity)
                // On today the control names the date; on another day the
                // title does, so it offers Today, as Calendar does.
                if model.isToday {
                    Text(dateLine)
                        .font(.system(size: 13))
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                        .padding(.horizontal, 4)
                } else {
                    Button(UserFacingCopy.Overview.today) { model.goToToday() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.horizontal, 4)
                }
                Button {
                    model.moveDay(1)
                } label: {
                    Image(systemName: "chevron.right").frame(width: 26, height: 24)
                }
                .help(UserFacingCopy.Overview.nextDay)
                .accessibilityLabel(UserFacingCopy.Overview.nextDay)
                .disabled(!model.canMoveForward)
                .opacity(model.nextDayArrowOpacity)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(MCI.Color.foregroundSecondary)
        }
    }

    private var dayTitle: String {
        if model.isToday { return UserFacingCopy.Overview.today }
        if model.isYesterday { return UserFacingCopy.Overview.yesterday }
        var calendar = model.calendar
        calendar.locale = locale
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).month(.wide).day()
        return model.selectedDate.formatted(style)
    }

    /// "Monday, October 12".
    private var dateLine: String {
        var calendar = model.calendar
        calendar.locale = locale
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).month(.wide).day()
        return model.selectedDate.formatted(style)
    }

    // MARK: Your day

    private var yourDay: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(UserFacingCopy.Overview.yourDay)
                    .font(MCI.Font.title2)
                    .foregroundStyle(MCI.Color.foreground)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let span = model.daySpan, !model.showsFirstDay {
                    Text(SessionDetail.timeRange(startUs: span.lowerBound, endUs: span.upperBound,
                                                 locale: locale, timeZone: timeZone))
                        .font(MCI.Font.caption)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                }
            }
            content
        }
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
            .padding(.vertical, 8)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(UserFacingCopy.Overview.loading)
                    .font(MCI.Font.body)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
            }
            .padding(.vertical, 8)
        }
    }

    private func emptyDay(_ overview: DayOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(overview.isToday ? UserFacingCopy.Overview.todayNothingYet : UserFacingCopy.Overview.pastDayEmpty)
                .font(MCI.Font.body)
                .foregroundStyle(MCI.Color.foregroundSecondary)
            modelLine(overview)
            // A first day has no card to offer "Connect" yet.
            if model.offersConnectOnEmptyDay {
                OverviewCard {
                    ConnectAIToolsRow()
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The first day's strip, empty, with now marked: the first session
    /// appears there.
    private func firstDay(_ overview: DayOverview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let layout = model.firstDayStrip {
                FirstDayStripView(layout: layout, remembering: model.isRemembering)
                    .padding(.top, 6)
            }
            modelLine(overview)
        }
        .transition(.opacity)
    }

    private func day(_ overview: DayOverview) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // Above the session, so a hover preview opening downwards is not
            // drawn under it.
            DayStripView(overview: overview, model: model, reader: reader, hover: $hover)
                .padding(.top, 6)
                .zIndex(1)
            if let block = model.selectedBlock {
                SessionDetailView(detail: SessionDetail(block: block, events: model.events,
                                                        locale: locale, timeZone: timeZone),
                                  reader: reader, open: open, search: openSearch, noticedOpen: $noticedOpen,
                                  showsCardActions: !model.selectedIsRightNow)
            }
            modelLine(overview)
        }
    }

    // MARK: Looked up today

    @ViewBuilder
    private var lookedUpToday: some View {
        let searches = model.lookedUpToday
        if !searches.isEmpty, !model.showsFirstDay {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(UserFacingCopy.Overview.lookedUpToday)
                        .font(MCI.Font.title2)
                        .foregroundStyle(MCI.Color.foreground)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if lookedUp != nil {
                        LinkButton(title: UserFacingCopy.Overview.all) { openLookedUp() }
                    }
                }
                QueryChips(queries: searches.map(\.query), search: openSearch)
            }
        }
    }

    // MARK: Summary

    @ViewBuilder
    private var summary: some View {
        if let account = model.overview?.account, !model.showsFirstDay, !(model.overview?.blocks.isEmpty ?? true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Button {
                        withAnimation(MCI.Motion.snap) { summaryOpen.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(MCI.Color.foregroundSecondary)
                                .rotationEffect(.degrees(summaryOpen ? 90 : 0))
                                .accessibilityHidden(true)
                            Text(UserFacingCopy.Overview.summaryTitle)
                                .font(MCI.Font.body)
                                .foregroundStyle(MCI.Color.foreground)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(summaryOpen ? .isSelected : [])
                    Spacer()
                    if let caption = UserFacingCopy.writtenOnThisMac(by: account.writtenBy) {
                        Text(caption)
                            .font(MCI.Font.caption)
                            .foregroundStyle(MCI.Color.foregroundSecondary)
                    }
                }
                if summaryOpen {
                    VStack(alignment: .leading, spacing: 6) {
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
                    }
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

/// The type's name before Today: the shell still says it until it moves to
/// `TodayPlace`.
typealias OverviewPlace = TodayPlace

/// "Also from yesterday: Q4 planning · Trailhead pricing v3 · Launch
/// checklist": Working On items from the last day of use, as links.
struct AlsoFromLine: View {
    let day: String
    let items: [WorkItem]
    let open: (RecallRoute) -> Void

    var body: some View {
        ChipFlow(spacing: 6) {
            Text(verbatim: UserFacingCopy.Overview.alsoFrom(day))
                .foregroundStyle(MCI.Color.foregroundSecondary)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 6) {
                    if index > 0 {
                        Text(verbatim: "\u{00B7}")
                            .foregroundStyle(MCI.Color.foregroundMuted)
                            .accessibilityHidden(true)
                    }
                    Button(item.name) { open(RecallRoute(workItem: item.id)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(MCI.Color.accent)
                        .accessibilityAddTraits(.isLink)
                }
            }
        }
        .font(.system(size: 13))
        .padding(.leading, 2)
    }
}

/// Today's one-time offer of the calendar (SPEC-DELTA 5) on any day but the
/// first, whose welcome card makes it: one line, Not Now and Show Calendar.
/// Either answer is final: the offer isn't made again.
struct CalendarOfferLine: View {
    let show: () -> Void
    let notNow: () -> Void
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "calendar")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .accessibilityHidden(true)
            Text(UserFacingCopy.Overview.showCalendarLine)
                .font(MCI.Font.body)
                .foregroundStyle(MCI.Color.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(CalendarCopy.notNow, action: notNow)
                .buttonStyle(.bordered)
                .disabled(isSyntheticPreview)
            Button(UserFacingCopy.Overview.showCalendar, action: show)
                .buttonStyle(.bordered)
                .disabled(isSyntheticPreview)
        }
        .padding(.vertical, 10)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MCI.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(MCI.Color.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// Why Hippocampus isn't remembering, when the window knows more than its
/// saved status: the shell sets it from the app's own words, and the first
/// day's card says what to do.
enum TodayStop: Equatable, Sendable {
    case paused
    case needsPermission
}

private struct TodayStopKey: EnvironmentKey {
    static let defaultValue: TodayStop? = nil
}

private struct ShowCalendarKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    /// Set by the shell while Hippocampus is paused or a permission is off.
    var todayStop: TodayStop? {
        get { self[TodayStopKey.self] }
        set { self[TodayStopKey.self] = newValue }
    }

    /// What "Show Calendar" does: the app asks macOS for Calendars access.
    /// Unset, it opens Preferences › General, where the calendar is turned on.
    var showCalendar: (@MainActor () -> Void)? {
        get { self[ShowCalendarKey.self] }
        set { self[ShowCalendarKey.self] = newValue }
    }
}
