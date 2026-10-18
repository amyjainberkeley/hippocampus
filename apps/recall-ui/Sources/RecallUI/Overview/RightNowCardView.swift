import RecallUIKit
import SwiftUI

/// The Right now card at the top of today's Overview (RULINGS W5): what you
/// are working on or what was saved last, "Copy for your AI", "Open {App}" or
/// "Open Page", and under it the exact lines a connected AI already has.
struct RightNowCardView: View {
    let card: RightNowCard
    let reader: BrainReader
    /// Folded, the card shows this many lines of each kind; "Show All" shows
    /// every line a connected AI is given.
    static let foldedRecent = 2
    static let foldedAbout = 2
    @State private var showsAllLines = false
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        OverviewCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if case .now = card.moment {
                            Circle()
                                .fill(DayStripPalette.color(DayStripPalette.accent))
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                        }
                        Text(card.caption(locale: locale, timeZone: timeZone))
                            .font(MCI.Font.caption)
                            .foregroundStyle(MCI.Color.foregroundSecondary)
                    }
                    Text(card.title)
                        .font(MCI.Font.title)
                        .foregroundStyle(MCI.Color.foreground)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    CopyForYourAIButton(title: card.title, range: card.copyRange, reader: reader, prominent: true)
                    if let reopen = card.reopen {
                        ReopenButton(action: reopen)
                    }
                }
                Divider()
                aiKnows
            }
        }
    }

    @ViewBuilder
    private var aiKnows: some View {
        switch card.aiKnows {
        case let .lines(recentWork, aboutYou):
            let recent = recentWork.map { $0.text(locale: locale, timeZone: timeZone) }
            let about = aboutYou.map(\.text)
            let folds = recent.count + about.count > Self.foldedRecent + Self.foldedAbout
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(UserFacingCopy.aiStartsWith)
                        .font(MCI.Font.bodyStrong)
                        .foregroundStyle(MCI.Color.foreground)
                    Spacer(minLength: 8)
                    if folds {
                        Button(showsAllLines ? UserFacingCopy.Overview.showLess : UserFacingCopy.Overview.showAll) {
                            showsAllLines.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(MCI.Font.caption)
                    }
                }
                if recent.isEmpty, about.isEmpty {
                    Text(UserFacingCopy.Overview.aiKnowsNothingYet)
                        .font(MCI.Font.caption)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                } else {
                    // Folded, each line is cut to one line on screen; the
                    // lines themselves are exactly what is sent.
                    let folded = folds && !showsAllLines
                    let shownRecent = folded ? Array(recent.prefix(Self.foldedRecent)) : recent
                    let shownAbout = folded
                        ? Array(about.prefix(Self.foldedRecent + Self.foldedAbout - shownRecent.count)) : about
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(shownRecent.enumerated()), id: \.offset) { _, line in
                            SentLine(text: line, oneLine: folded)
                        }
                        if !shownRecent.isEmpty, !shownAbout.isEmpty {
                            Spacer().frame(height: 4)
                        }
                        ForEach(Array(shownAbout.enumerated()), id: \.offset) { _, line in
                            SentLine(text: line, oneLine: folded)
                        }
                    }
                }
            }
        case .connect:
            ConnectAIToolsRow()
        }
    }
}

/// One line and "Connect", shown instead of "What your AI starts with" while
/// no AI tool starts its sessions with Hippocampus (RULINGS W5).
struct ConnectAIToolsRow: View {
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(UserFacingCopy.Overview.connectLine)
                .font(MCI.Font.body)
                .foregroundStyle(MCI.Color.foregroundSecondary)
            Spacer(minLength: 8)
            Button(UserFacingCopy.connectAction) { openAITools() }
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
