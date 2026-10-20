import AppKit
import RecallUIKit
import SwiftUI
import UniformTypeIdentifiers

/// The selected session on Today (SPEC 3.1): its title (a call's or
/// meeting's is its calendar event's), time and length, its kind in the
/// sidebar's words, its apps with their minutes, what Hippocampus noticed
/// with who wrote it, "You looked up", the Ask button and Show in History,
/// and its screenshot. Nothing here counts what the person did (RULINGS W4).
struct SessionDetailView: View {
    let detail: SessionDetail
    let reader: BrainReader
    let open: (RecallRoute) -> Void
    let search: (String) -> Void
    @Binding var noticedOpen: Bool
    /// False for the session the card at the top already shows: its Ask
    /// button is on the card, so it is not repeated.
    var showsCardActions = true

    var body: some View {
        OverviewCard {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if !detail.apps.isEmpty {
                        AppTimes(apps: detail.apps)
                    }
                    if !detail.sentences.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(detail.sentences.enumerated()), id: \.offset) { _, sentence in
                                Text(sentence)
                                    .font(MCI.Font.body)
                                    .foregroundStyle(MCI.Color.foreground)
                            }
                        }
                    }
                    if let noticed = detail.noticed {
                        DisclosureGroup(isExpanded: $noticedOpen) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(noticed.text)
                                    .font(MCI.Font.body)
                                    .foregroundStyle(MCI.Color.foreground)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                if let caption = noticed.caption {
                                    Text(caption)
                                        .font(MCI.Font.footnote)
                                        .foregroundStyle(MCI.Color.foregroundMuted)
                                }
                            }
                            .padding(.top, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Text(UserFacingCopy.Overview.noticedTitle)
                                .font(MCI.Font.body)
                                .foregroundStyle(MCI.Color.foreground)
                        }
                    }
                    if !detail.searches.isEmpty {
                        SearchChips(queries: detail.searches, search: search)
                    }
                    actions
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SessionScreenshot(eventId: detail.screenshotEventId, reader: reader,
                                  size: CGSize(width: 240, height: 150), fallbackApp: detail.apps.first?.bundleId)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(detail.title)
                .font(MCI.Font.title2)
                .foregroundStyle(MCI.Color.foreground)
                .lineLimit(2)
                .textSelection(.enabled)
            Text(UserFacingCopy.Overview.timeAndLength(detail.time, detail.length))
                .font(MCI.Font.body)
                .foregroundStyle(MCI.Color.foregroundSecondary)
            HStack(spacing: 6) {
                Circle()
                    .fill(DayStripPalette.color(for: detail.stripKind))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(detail.kindLine)
                    .font(MCI.Font.caption)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if showsCardActions {
                AskAIButton(source: .session(title: detail.title, range: detail.copyRange), reader: reader)
            }
            Button(UserFacingCopy.showInHistory) { open(detail.history) }
                .buttonStyle(.bordered)
        }
        .padding(.top, 2)
    }
}

/// An app of a session with its minutes: icon, "Notes 19 min".
struct AppTimeLabel: View {
    let app: SessionDetail.AppTime

    var body: some View {
        HStack(spacing: 6) {
            AppIcon(bundleId: app.bundleId)
                .frame(width: 16, height: 16)
            Text(app.label)
                .font(MCI.Font.caption)
                .foregroundStyle(MCI.Color.foregroundSecondary)
        }
    }
}

/// The app's own icon when it is on this Mac, else the first letter of its
/// name on a soft tile (`AppMonogram`). Never the system's blank placeholder,
/// which reads as a missing picture.
struct AppIcon: View {
    let bundleId: String

    var body: some View {
        if let icon = AppIconCache.shared.icon(for: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .accessibilityHidden(true)
        } else {
            AppMonogram(bundleId: bundleId)
        }
    }
}

/// Searches as chips; clicking one searches for it in Ask.
struct SearchChips: View {
    let queries: [String]
    let search: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(UserFacingCopy.Overview.lookedUp)
                .font(MCI.Font.caption)
                .foregroundStyle(MCI.Color.foregroundMuted)
            QueryChips(queries: queries, search: search)
        }
    }
}

/// Searches as chips, each in quotes as it was typed; clicking one opens it.
struct QueryChips: View {
    let queries: [String]
    let search: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChipFlow(spacing: 6) {
                ForEach(queries, id: \.self) { query in
                    Button {
                        search(query)
                    } label: {
                        Text(verbatim: "\u{201C}\(query)\u{201D}")
                            .font(MCI.Font.caption)
                            .foregroundStyle(MCI.Color.foreground)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(MCI.Color.background))
                            .overlay(Capsule().stroke(MCI.Color.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(query)
                }
            }
        }
    }
}

/// Lays chips out in rows, wrapping at the available width.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
