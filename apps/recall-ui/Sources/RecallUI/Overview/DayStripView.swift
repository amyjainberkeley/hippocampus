import RecallUIKit
import SwiftUI

/// The day strip (RULINGS W6, contract overview.md section 6): sessions as
/// blocks coloured by kind on the day's hours, time with nothing saved as
/// empty space, a hairline where two sessions touch. Hovering a session shows
/// its screenshot, so the day scrubs; clicking selects it; left and right
/// arrows move between sessions. Under it, the legend: clicking a kind dims
/// the rest.
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

    static let stripHeight: CGFloat = 40
    private static let tickHeight: CGFloat = 18
    private static let previewSize = CGSize(width: 208, height: 130)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                if let layout = DayStripLayout(overview: overview, minimumWidth: 6 / width, calendar: model.calendar) {
                    strip(layout, width: width)
                }
            }
            .frame(height: Self.stripHeight + Self.tickHeight)
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

    private func strip(_ layout: DayStripLayout, width: CGFloat) -> some View {
        let blocks = Dictionary(uniqueKeysWithValues: overview.blocks.map { ($0.id, $0) })
        let selected = model.selectedBlock?.id
        return ZStack(alignment: .topLeading) {
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
            if let hover {
                preview(hover, layout: layout, blocks: blocks, width: width)
            }
        }
        .frame(width: width, height: Self.stripHeight + Self.tickHeight, alignment: .topLeading)
    }

    private func blockView(_ placed: DayStripLayout.Block, block: DayBlock, width: CGFloat, isSelected: Bool) -> some View {
        // A two-point gap of the strip's own colour is the hairline between
        // sessions that touch.
        let inset: CGFloat = placed.touchesPrevious ? 2 : 0
        let blockWidth = max(placed.width * width - inset, 4)
        let color = DayStripPalette.color(for: block.kind)
        let time = SessionDetail.timeRange(startUs: block.startUs, endUs: block.endUs, locale: locale, timeZone: timeZone)
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
        .help(UserFacingCopy.Overview.sessionHelp(title: block.title, time: time))
        .accessibilityLabel(UserFacingCopy.Overview.sessionHelp(title: block.title, time: time))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { inside in
            if inside { hover = .session(block.id) } else if hover == .session(block.id) { hover = nil }
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

    @ViewBuilder
    private func preview(_ hover: StripHover, layout: DayStripLayout, blocks: [Int64: DayBlock], width: CGFloat) -> some View {
        switch hover {
        case let .session(id):
            if let block = blocks[id], let placed = layout.blocks.first(where: { $0.id == id }) {
                let cardWidth = Self.previewSize.width + 16
                let center = (placed.x + placed.width / 2) * width
                let x = min(max(center - cardWidth / 2, 0), max(width - cardWidth, 0))
                VStack(alignment: .leading, spacing: 6) {
                    SessionScreenshot(eventId: block.screenshotEventId, reader: reader, size: Self.previewSize)
                    Text(block.title)
                        .font(MCI.Font.bodyStrong)
                        .foregroundStyle(MCI.Color.foreground)
                        .lineLimit(1)
                    Text(SessionDetail.timeRange(startUs: block.startUs, endUs: block.endUs, locale: locale, timeZone: timeZone))
                        .font(MCI.Font.caption)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                }
                .padding(8)
                .frame(width: cardWidth, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MCI.Color.surfaceElevated))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(MCI.Color.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .offset(x: x, y: -(Self.previewSize.height + 64))
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
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(MCI.Color.border, lineWidth: 1))
            .offset(x: x, y: -56)
            .allowsHitTesting(false)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(overview.kinds, id: \.kind) { entry in
                let picked = model.highlightedKind
                Button {
                    model.toggleHighlight(entry.kind)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(DayStripPalette.color(for: entry.kind))
                            .frame(width: 8, height: 8)
                        Text(entry.kindLabel)
                            .font(MCI.Font.caption)
                            .foregroundStyle(picked == entry.kind ? MCI.Color.foreground : MCI.Color.foregroundSecondary)
                            .fontWeight(picked == entry.kind ? .semibold : .regular)
                    }
                    .opacity(picked == nil || picked == entry.kind ? 1 : 0.45)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.kindLabel)
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
