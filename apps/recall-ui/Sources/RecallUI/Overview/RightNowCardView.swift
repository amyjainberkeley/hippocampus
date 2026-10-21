import AppKit
import RecallUIKit
import SwiftUI

/// The card at the top of Today (SPEC 3.1, SPEC-DELTA 3): "Now · since 2:12
/// PM" or "Where you left off · Yesterday at 6:12 PM"; the session's title;
/// its newest moment as History draws it; its apps with their minutes; its
/// screenshot; "Part of trailhead-shop ›"; then Resume when the session is
/// part of a Working On item, the Ask button, Open {App} or Open Page, Show
/// in History, and the ⋯ menu.
struct TodayCardView: View {
    let card: RightNowCard
    @ObservedObject var model: OverviewViewModel
    let reader: BrainReader
    let open: (RecallRoute) -> Void

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.forget) private var forget
    @Environment(\.handoffServices) private var handoff
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview

    private typealias Copy = UserFacingCopy.Overview

    private var title: String { model.cardTitle ?? card.title }

    private var apps: [SessionDetail.AppTime] {
        SessionDetail.AppTime.of(card.block?.apps ?? [], locale: locale)
    }

    var body: some View {
        OverviewCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 20) {
                    info
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SessionScreenshot(eventId: card.block?.screenshotEventId ?? card.openEventId, reader: reader,
                                      size: CGSize(width: 240, height: 150),
                                      fallbackApp: card.block?.apps.first?.bundleId)
                        .accessibilityLabel(screenshotLabel)
                }
                actions
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.cardLabel(card.caption(locale: locale, timeZone: timeZone), title: title,
                                           apps: apps.map(\.name)))
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if case .now = card.moment {
                    Circle()
                        .fill(MCI.Color.accentFill)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text(card.caption(locale: locale, timeZone: timeZone))
                    .font(MCI.Font.caption)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
            }
            Text(verbatim: title)
                .font(MCI.Font.title)
                .foregroundStyle(MCI.Color.foreground)
                .lineLimit(2)
                .textSelection(.enabled)
                .padding(.top, 2)
            if let moment = model.cardMoment {
                MomentLine(hit: moment)
                    .padding(.top, 8)
            }
            if !apps.isEmpty {
                AppTimes(apps: apps)
                    .padding(.top, 10)
            }
            if model.showsPartOf, let item = model.cardItem {
                PartOfLink(name: item.name) { open(RecallRoute(workItem: item.id)) }
                    .padding(.top, 6)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let item = model.cardItem {
                // Native, as the buttons beside it are.
                Button(WorkCopy.resume) { open(.resume(item: item.id)) }
                    .resumeButtonStyle()
                    .help(WorkCopy.resume)
            }
            askButton
            // An app that was removed from the Mac has no Open button.
            if let reopen = card.reopen, reopen.canOpen() {
                ReopenButton(action: reopen)
            }
            Button(UserFacingCopy.showInHistory) {
                open(.history(of: card.copyRange, selecting: card.openEventId))
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 8)
            Menu {
                Button(LibraryCopy.History.copyForYourAI) { copyForYourAI() }
                if let forget {
                    Divider()
                    Button(Copy.forgetSession(range)) { forget(.range(card.copyRange, label: range)) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel(Copy.more)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Copy.more)
        }
    }

    /// Ask {Tool} for the card (SPEC 5.3.1): on a code project it opens
    /// Claude Code in the project's folder with where you left off; otherwise
    /// the session's moments. The main button when there is nothing to
    /// resume. ⌘↩ is this button.
    @ViewBuilder
    private var askButton: some View {
        // Another session picked on the strip has ⌘↩ instead.
        let commandReturn = model.selectedBlock == nil || model.selectedIsRightNow
        if let item = model.cardItem, item.kind == .code {
            AskAIButton(source: .item(item.id), reader: reader, handlesCommandReturn: commandReturn,
                        itemMoments: item.moments, codeProject: item.name)
        } else {
            AskAIButton(source: .session(title: title, range: card.copyRange), reader: reader,
                        prominent: model.cardItem == nil, handlesCommandReturn: commandReturn)
        }
    }

    /// "2:12 to 2:36 PM": the session's own time, as its Forget names it.
    private var range: String {
        TodayFormat.span(card.copyRange, locale: locale, timeZone: timeZone)
    }

    private var screenshotLabel: String {
        Copy.screenshotLabel(title, time: Formatters.clockTime(us: card.copyRange.upperBound,
                                                              locale: locale, timeZone: timeZone))
    }

    /// The builder's message for the session, by the clipboard rules
    /// (SPEC 5.3.6): this Mac only, kept out of clipboard history, cleared
    /// after 2 minutes.
    private func copyForYourAI() {
        let services = HandoffServices.resolved(handoff, isSyntheticPreview: isSyntheticPreview)
        let source = AskAISource.session(title: title, range: card.copyRange)
        Task { await AskAIButton.copyForYourAI(source, services: services) }
    }
}

/// A moment drawn as History draws it, on a card: its caption and time,
/// then two lines of what the window said.
struct MomentLine: View {
    let hit: Hit
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: MomentRowText.headline(hit))
                    .font(MCI.Font.bodyStrong)
                    .foregroundStyle(MCI.Color.foreground)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: Formatters.clockTime(us: Int64(clamping: hit.tsUs), locale: locale, timeZone: timeZone))
                    .font(MCI.Font.caption)
                    .monospacedDigit()
                    .foregroundStyle(MCI.Color.foregroundSecondary)
            }
            if let lines = MomentRowText.codeLines(hit) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.prefix(2).enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(MCI.Color.foregroundSecondary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text(verbatim: MomentRowText.preview(hit))
                    .font(MCI.Font.body)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A session's apps with their minutes: "VS Code 9 min  Chrome 8 min".
struct AppTimes: View {
    let apps: [SessionDetail.AppTime]

    var body: some View {
        ChipFlow(spacing: 14) {
            ForEach(apps) { app in
                AppTimeLabel(app: app)
            }
        }
    }
}

/// "Part of trailhead-shop ›": the Working On item a moment or a session
/// belongs to, which it opens.
struct PartOfLink: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(verbatim: LibraryCopy.History.partOf(name))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13))
            .foregroundStyle(MCI.Color.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LibraryCopy.History.partOf(name))
        .accessibilityAddTraits(.isLink)
    }
}

/// One line and "Connect…", where nothing yet starts an AI tool's sessions
/// with Hippocampus (RULINGS W5).
struct ConnectAIToolsRow: View {
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(UserFacingCopy.Overview.connectRecentWork)
                .font(MCI.Font.body)
                .foregroundStyle(MCI.Color.foregroundSecondary)
            Spacer(minLength: 8)
            Button(UserFacingCopy.Overview.connect) { openAITools() }
                .buttonStyle(.bordered)
                .disabled(isSyntheticPreview)
        }
    }
}

/// One line exactly as a connected AI is given it.
struct SentLine: View {
    let text: String
    /// Cut to one line on screen, with the whole line as its help text.
    var oneLine = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(MCI.Color.borderStrong)
                .frame(width: 2, height: 12)
                .accessibilityHidden(true)
            if oneLine {
                Text(text)
                    .font(MCI.Font.caption)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(text)
            } else {
                Text(text)
                    .font(MCI.Font.caption)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Times on Today, in the person's format.
enum TodayFormat {
    /// "2:12 to 2:36 PM": a span as Forget names it.
    static func span(_ range: ClosedRange<Int64>, locale: Locale, timeZone: TimeZone) -> String {
        let text = SessionDetail.timeRange(startUs: range.lowerBound, endUs: range.upperBound,
                                           locale: locale, timeZone: timeZone)
        for dash in ["\u{2009}\u{2013}\u{2009}", " \u{2013} ", "\u{2013}"] where text.contains(dash) {
            return text.replacingOccurrences(of: dash, with: " to ")
        }
        return text
    }
}
