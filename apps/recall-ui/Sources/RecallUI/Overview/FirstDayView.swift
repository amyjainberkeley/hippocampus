import RecallUIKit
import SwiftUI

/// Today on the first day of the person's memory, before its first session:
/// where they land after setup (first landing, Oct 18; SPEC 3.1.1). It sits
/// where the card will be: the hi mark, one line on what has begun, what to
/// try first, the calendar offered once (SPEC-DELTA 5), and as soon as
/// anything is saved, how much and the newest moment, drawn as History draws
/// it. The day keeps its place below, empty, with now marked
/// (`FirstDayStripView`); the first session takes over both as it is saved.
struct FirstDayCard: View {
    /// By the sidebar footer's rule: the card never says memory has started
    /// while nothing is being saved.
    let remembering: Bool
    /// Why it isn't, when the window knows: paused or a permission off say so.
    var stopped: TodayStop? = nil
    /// No AI tool starts its sessions with Hippocampus yet.
    let offersConnect: Bool
    /// The calendar is offered here once.
    var offersCalendar = false
    /// "Saved so far: 6 moments.", and the newest of them.
    var savedSoFar: UInt64? = nil
    var newest: Hit? = nil
    var showCalendar: () -> Void = {}
    var open: (RecallRoute) -> Void = { _ in }
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview

    private typealias Copy = UserFacingCopy.Overview

    private var lead: String {
        if remembering { return Copy.firstDayBody }
        switch stopped {
        case .paused?: return Copy.firstDayPausedBody
        case .needsPermission?: return Copy.firstDayPermissionBody
        default: return Copy.firstDayOffBody
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HiTileView(size: 44, remembering: remembering)
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                Text(remembering ? Copy.firstDayTitle : Copy.firstDayOffTitle)
                    .font(MCI.Font.title)
                    .foregroundStyle(MCI.Color.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
                Text(lead)
                    .font(MCI.Font.body)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(EdgeInsets(top: 26, leading: 28, bottom: 24, trailing: 28))
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    AskKeyCap()
                        .frame(width: 44)
                    Text(Copy.firstDayAsk(AskShortcutLabel.current().phrase))
                        .font(MCI.Font.body)
                        .foregroundStyle(MCI.Color.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if offersConnect {
                    GridRow {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(MCI.Color.foregroundSecondary)
                            .frame(width: 44)
                            .accessibilityHidden(true)
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(Copy.connectRecentWork)
                                .font(MCI.Font.body)
                                .foregroundStyle(MCI.Color.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button(Copy.connect) { openAITools() }
                                .buttonStyle(.bordered)
                                .disabled(isSyntheticPreview)
                        }
                    }
                }
                if offersCalendar {
                    GridRow {
                        Image(systemName: "calendar")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(MCI.Color.foregroundSecondary)
                            .frame(width: 44)
                            .accessibilityHidden(true)
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(Copy.showCalendarLine)
                                .font(MCI.Font.body)
                                .foregroundStyle(MCI.Color.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button(Copy.showCalendar, action: showCalendar)
                                .buttonStyle(.bordered)
                                .disabled(isSyntheticPreview)
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 16, leading: 28, bottom: 16, trailing: 28))
            if let savedSoFar, savedSoFar > 0 {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Copy.savedSoFar(savedSoFar))
                            .font(MCI.Font.body)
                            .foregroundStyle(MCI.Color.foreground)
                        Spacer(minLength: 8)
                        LinkButton(title: Copy.seeThemInHistory) { open(.showHistory) }
                    }
                    if let newest {
                        Button {
                            let at = Int64(clamping: newest.tsUs)
                            open(.history(of: at...at, selecting: Int64(clamping: newest.id)))
                        } label: {
                            HitRow(hit: newest, showsClockTime: true)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(EdgeInsets(top: 16, leading: 28, bottom: 16, trailing: 28))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MCI.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(MCI.Color.border, lineWidth: 1))
    }
}

/// Words that open a place, in the accent with a chevron: "See Them in
/// History ›", "All ›".
struct LinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(verbatim: title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13))
            .foregroundStyle(MCI.Color.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isLink)
    }
}

/// The key that opens Ask, drawn as a key: "⇧⇧", "right ⌘", "⌃⇧Space".
private struct AskKeyCap: View {
    var body: some View {
        let shortcut = AskShortcutLabel.current()
        if shortcut.opensAsk {
            Text(shortcut.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MCI.Color.foreground)
                .padding(.horizontal, 8)
                .frame(minWidth: 34, minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(MCI.Color.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(MCI.Color.borderStrong, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 0, y: 1)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "keyboard")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .accessibilityHidden(true)
        }
    }
}

/// Today's strip on the first day, before its first session: the hours
/// around now, empty, with now marked where the first session will appear.
/// While Hippocampus is remembering, the mark is the window's blue with a
/// slow halo; otherwise it is grey and still.
struct FirstDayStripView: View {
    let layout: FirstDayStripLayout
    let remembering: Bool
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    private static let tickHeight: CGFloat = 18
    private static let markSize: CGFloat = 30

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(MCI.Color.border.opacity(0.45))
                    .frame(width: width, height: DayStripView.stripHeight)
                nowLabel(width: width)
                NowMark(live: remembering)
                    .id(remembering)
                    .offset(x: markX(width) - Self.markSize / 2,
                            y: (DayStripView.stripHeight - Self.markSize) / 2)
                ForEach(Array(layout.ticks.enumerated()), id: \.offset) { _, tick in
                    tickLabel(tick, width: width)
                }
            }
            .frame(width: width, height: DayStripView.stripHeight + Self.tickHeight, alignment: .topLeading)
        }
        .frame(height: DayStripView.stripHeight + Self.tickHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UserFacingCopy.Overview.stripLabel)
        .accessibilityValue(UserFacingCopy.Overview.now)
    }

    /// Now, kept clear of the strip's rounded ends.
    private func markX(_ width: CGFloat) -> CGFloat {
        min(max(layout.nowX * width, 10), width - 10)
    }

    /// "Now" beside the mark, inside the strip: before it, or after it when
    /// now is at the strip's start (just after midnight).
    private func nowLabel(width: CGFloat) -> some View {
        let labelWidth: CGFloat = 44
        let x = markX(width)
        let before = x > labelWidth + 16
        return Text(UserFacingCopy.Overview.now)
            .font(MCI.Font.caption)
            .foregroundStyle(remembering ? DayStripPalette.color(DayStripPalette.accent) : MCI.Color.foregroundSecondary)
            .frame(width: labelWidth, height: 16, alignment: before ? .trailing : .leading)
            .offset(x: before ? x - labelWidth - 10 : x + 10, y: (DayStripView.stripHeight - 16) / 2)
            .accessibilityHidden(true)
    }

    /// The hour labels, placed as the day strip places them.
    private func tickLabel(_ tick: DayStripLayout.Tick, width: CGFloat) -> some View {
        let label = Formatters.clockHour(us: tick.atUs, locale: locale, timeZone: timeZone)
        let labelWidth: CGFloat = 44
        let x = min(max(tick.x * width - labelWidth / 2, 0), width - labelWidth)
        let alignment: Alignment = tick.x * width < labelWidth / 2 ? .leading
            : tick.x * width > width - labelWidth / 2 ? .trailing : .center
        return Text(label)
            .font(MCI.Font.footnote)
            .foregroundStyle(MCI.Color.foregroundMuted)
            .frame(width: labelWidth, alignment: alignment)
            .offset(x: x, y: DayStripView.stripHeight + 4)
            .accessibilityHidden(true)
    }
}

/// Now on the first day's strip. A slow halo says Hippocampus is remembering;
/// with Reduce Motion, or while it is not, the mark is still.
private struct NowMark: View {
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        let color = live ? DayStripPalette.color(DayStripPalette.accent) : MCI.Color.foregroundMuted
        ZStack {
            if live, !reduceMotion {
                Circle()
                    .fill(color.opacity(0.3))
                    .frame(width: 12, height: 12)
                    .scaleEffect(expanded ? 2.4 : 1)
                    .opacity(expanded ? 0 : 1)
            }
            Circle()
                .fill(MCI.Color.surface)
                .frame(width: 16, height: 16)
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
        }
        .frame(width: 30, height: 30)
        .onAppear {
            guard live, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) {
                expanded = true
            }
        }
    }
}
