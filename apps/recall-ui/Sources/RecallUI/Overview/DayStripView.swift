import RecallUIKit
import SwiftUI

/// The day strip (RULINGS W6, contract overview.md section 6, SPEC 2.14 and
/// 3.1): sessions as blocks coloured by kind on the day's hours, time with
/// nothing saved as empty space, a hairline where two sessions touch.
/// Hovering a session shows its screenshot, so the day scrubs; clicking
/// selects it; left and right arrows move between sessions; right-clicking
/// one offers to forget its time. Over it, when the calendar may be read,
/// today's events as thin labelled bars (SPEC-DELTA 5). Under it, the legend
/// in the sidebar's words: clicking a kind dims the rest.
struct DayStripView: View {
    let overview: DayOverview
    @ObservedObject var model: OverviewViewModel
    let reader: BrainReader
    /// Scrubbing previews: the session or empty time under the pointer.
    @Binding var hover: StripHover?
    /// The strip takes the keyboard when a session is clicked, so the
    /// arrows move from there.
    @FocusState private var isFocused: Bool
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.forget) private var forget
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let stripHeight: CGFloat = 40
    private static let tickHeight: CGFloat = 18
    private static let previewSize = CGSize(width: 184, height: 115)
    /// One row of calendar bars: its title over a thin bar.
    static let laneHeight: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                if let layout = DayStripLayout(overview: overview, minimumWidth: 6 / width,
                                               calendar: model.calendar, span: model.stripSpan) {
                    strip(layout, width: width)
                }
            }
            .frame(height: barsHeight + Self.stripHeight + Self.tickHeight)
            .zIndex(1)
            legend
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            model.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            model.moveSelection(by: 1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(UserFacingCopy.Overview.stripLabel)
    }

    private var bars: [TodayCalendar.Bar] {
        guard let span = model.stripSpan else { return [] }
        return TodayCalendar.bars(model.events, startUs: span.startUs, endUs: span.endUs)
    }

    private var barsHeight: CGFloat {
        let lanes = (bars.map(\.lane).max() ?? -1) + 1
        return CGFloat(lanes) * Self.laneHeight
    }

    private func strip(_ layout: DayStripLayout, width: CGFloat) -> some View {
        let blocks = Dictionary(uniqueKeysWithValues: overview.blocks.map { ($0.id, $0) })
        let selected = model.selectedBlock?.id
        let top = barsHeight
        return ZStack(alignment: .topLeading) {
            ForEach(bars) { bar in
                calendarBar(bar, width: width)
            }
            Group {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(MCI.Color.border.opacity(0.45))
                    .frame(width: width, height: Self.stripHeight)
                ForEach(Array(layout.nothingSaved.enumerated()), id: \.offset) { _, span in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: max(span.width * width, 1), height: Self.stripHeight)
                        .offset(x: span.x * width)
                        .help(UserFacingCopy.Overview.nothingSaved)
                        .onHover { inside in
                            if inside { hover = .nothingSaved(span) } else if hover == .nothingSaved(span) { hover = nil }
                        }
                }
                ForEach(layout.blocks) { placed in
                    if let block = blocks[placed.id] {
                        blockView(placed, block: block, width: width, isSelected: placed.id == selected)
                    }
                }
                ForEach(Array(layout.ticks.enumerated()), id: \.offset) { index, tick in
                    tickLabel(tick, index: index, count: layout.ticks.count, width: width)
                }
            }
            .offset(y: top)
            if let hover {
                preview(hover, layout: layout, blocks: blocks, width: width)
                    .offset(y: top)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(MCI.Motion.snap, value: hover)
        .frame(width: width, height: top + Self.stripHeight + Self.tickHeight, alignment: .topLeading)
    }

    /// One calendar event: its title over a thin bar for its time.
    private func calendarBar(_ bar: TodayCalendar.Bar, width: CGFloat) -> some View {
        let x = bar.x * width
        let barWidth = max(bar.width * width, 3)
        let time = SessionDetail.timeRange(startUs: bar.startUs, endUs: bar.endUs, locale: locale, timeZone: timeZone)
        let label = UserFacingCopy.Overview.calendarItem(bar.title, time: time)
        // A short event's title may run past its bar, up to the strip's edge.
        let labelWidth = max(min(width - x, max(barWidth, 120)), barWidth)
        return VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: bar.title)
                .font(MCI.Font.footnote)
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: labelWidth, alignment: .leading)
            Capsule(style: .continuous)
                .fill(MCI.Color.accentDim.opacity(0.55))
                .frame(width: barWidth, height: 3)
        }
        .frame(width: labelWidth, alignment: .leading)
        .offset(x: x, y: CGFloat(bar.lane) * Self.laneHeight)
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func blockView(_ placed: DayStripLayout.Block, block: DayBlock, width: CGFloat, isSelected: Bool) -> some View {
        // A two-point gap of the strip's own colour is the hairline between
        // sessions that touch.
        let inset: CGFloat = placed.touchesPrevious ? 2 : 0
        let blockWidth = max(placed.width * width - inset, 4)
        let color = DayStripPalette.color(for: placed.stripKind)
        let time = SessionDetail.timeRange(startUs: block.startUs, endUs: block.endUs, locale: locale, timeZone: timeZone)
        let title = model.title(of: block)
        return Button {
            model.select(block)
            isFocused = true
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.opacity(placed.inProgress ? 0.55 : 1))
                .overlay {
                    if placed.inProgress {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(color, lineWidth: 1.5)
                    }
                }
                .overlay {
                    // Selection is the accent, as everywhere in the window
                    // (RULINGS B4), set off from the block by a gap.
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(DayStripPalette.color(DayStripPalette.accent), lineWidth: 2)
                            .padding(-4)
                    }
                }
                .frame(width: blockWidth, height: Self.stripHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(model.isDimmed(block) ? 0.22 : 1)
        .offset(x: placed.x * width + inset)
        .help(UserFacingCopy.Overview.sessionHelp(title: title, time: time))
        .accessibilityLabel(UserFacingCopy.Overview.sessionHelp(title: title, time: time))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { inside in
            if inside { hover = .session(block.id) } else if hover == .session(block.id) { hover = nil }
        }
        .contextMenu {
            if let forget {
                let range = TodayFormat.span(block.startUs...block.endUs, locale: locale, timeZone: timeZone)
                Button(UserFacingCopy.Overview.forgetSession(range)) {
                    forget(.range(block.startUs...block.endUs, label: range))
                }
            }
        }
    }

    private func tickLabel(_ tick: DayStripLayout.Tick, index: Int, count: Int, width: CGFloat) -> some View {
        let label = Formatters.clockHour(us: tick.atUs, locale: locale, timeZone: timeZone)
        let labelWidth: CGFloat = 44
        let x = min(max(tick.x * width - labelWidth / 2, 0), width - labelWidth)
        let alignment: Alignment = tick.x * width < labelWidth / 2 ? .leading
            : tick.x * width > width - labelWidth / 2 ? .trailing : .center
        return Text(label)
            .font(MCI.Font.footnote)
            .foregroundStyle(MCI.Color.foregroundMuted)
            .frame(width: labelWidth, alignment: alignment)
            .offset(x: x, y: Self.stripHeight + 4)
            .accessibilityHidden(true)
    }

    /// Previews open under the hour labels: above the strip they would be
    /// cut off when the strip is near the top of the page (a past day).
    private static let previewTop = stripHeight + tickHeight + 6

    @ViewBuilder
    private func preview(_ hover: StripHover, layout: DayStripLayout, blocks: [Int64: DayBlock], width: CGFloat) -> some View {
        switch hover {
        case let .session(id):
            if let block = blocks[id], let placed = layout.blocks.first(where: { $0.id == id }) {
                let cardWidth = Self.previewSize.width + 12
                let center = (placed.x + placed.width / 2) * width
                let x = min(max(center - cardWidth / 2, 0), max(width - cardWidth, 0))
                VStack(alignment: .leading, spacing: 4) {
                    SessionScreenshot(eventId: block.screenshotEventId, reader: reader, size: Self.previewSize,
                                      fallbackApp: block.apps.first?.bundleId)
                    Text(model.title(of: block))
                        .font(MCI.Font.bodyStrong)
                        .foregroundStyle(MCI.Color.foreground)
                        .lineLimit(1)
                        .padding(.horizontal, 2)
                        .padding(.top, 3)
                    Text(UserFacingCopy.Overview.timeAndLength(
                        SessionDetail.timeRange(startUs: block.startUs, endUs: block.endUs, locale: locale, timeZone: timeZone),
                        UserFacingCopy.Overview.minutes(block.endUs - block.startUs, locale: locale)))
                        .font(MCI.Font.caption)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                        .padding(.horizontal, 2)
                }
                .padding(6)
                .padding(.bottom, 2)
                .frame(width: cardWidth, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MCI.Color.surfaceElevated))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(MCI.Color.border, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 15, y: 10)
                .offset(x: x, y: Self.previewTop)
                .allowsHitTesting(false)
            }
        case let .nothingSaved(span):
            let center = (span.x + span.width / 2) * width
            let cardWidth: CGFloat = 170
            let x = min(max(center - cardWidth / 2, 0), max(width - cardWidth, 0))
            VStack(alignment: .leading, spacing: 2) {
                Text(UserFacingCopy.Overview.nothingSaved)
                    .font(MCI.Font.bodyStrong)
                    .foregroundStyle(MCI.Color.foreground)
                Text(SessionDetail.timeRange(startUs: span.startUs, endUs: span.endUs, locale: locale, timeZone: timeZone))
                    .font(MCI.Font.caption)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
            }
            .padding(8)
            .frame(width: cardWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MCI.Color.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(MCI.Color.border, lineWidth: 0.5))
            .offset(x: x, y: Self.previewTop)
            .allowsHitTesting(false)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(DayStripLayout.legend(overview.blocks)) { entry in
                let picked = model.highlightedKind
                Button {
                    model.toggleHighlight(entry.kind)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(DayStripPalette.color(for: entry.kind))
                            .frame(width: 8, height: 8)
                        Text(entry.kind.title)
                            .font(MCI.Font.caption)
                            .foregroundStyle(picked == entry.kind ? MCI.Color.foreground : MCI.Color.foregroundSecondary)
                            .fontWeight(picked == entry.kind ? .semibold : .regular)
                    }
                    .opacity(picked == nil || picked == entry.kind ? 1 : 0.45)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.kind.title)
                .accessibilityHint(UserFacingCopy.Overview.legendHint)
                .accessibilityAddTraits(picked == entry.kind ? .isSelected : [])
            }
        }
    }
}

/// What the pointer is over on the strip.
enum StripHover: Equatable {
    case session(Int64)
    case nothingSaved(DayStripLayout.Span)
}
