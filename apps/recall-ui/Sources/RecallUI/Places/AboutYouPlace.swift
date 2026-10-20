import RecallUIKit
import SwiftUI

/// About You (SPEC 3.7): what your AI tools can be told about you, in the
/// exact words sent, for you to correct (RULINGS I7, I8, I10; contract
/// model-page.md).
///
/// The groups as headings ("Projects and goals", "How you work", Skills,
/// People, "Where you got stuck"), each line with where it came from, Why,
/// Right and Forget; a line that names a Working On item exactly links to
/// it. A line no AI tool is given yet sits in its group after the ones that
/// are, saying "Not sent yet", and one line under the lead says what that
/// means. At the bottom, one row: "Not sent unless your AI looks it up · Not
/// seen lately · Names You Use…", then who wrote it. "Recent work" moved to
/// AI Tools; Privacy and AI Tools are rows of the sidebar now.
///
/// The shell owns the model (built with the verdict inbox) and routes:
/// a session row opens it on Today, an item link its page, and Names You
/// Use… pushes the names editor (`.you` with `[.names]`).
struct AboutYouPlace: View {
    @ObservedObject var model: UserModelViewModel
    let open: (RecallRoute) -> Void
    /// Working On's items, so a line that names one links to it.
    var items: [WorkItem] = []

    @State private var keptBackOpen: Bool
    @State private var notSeenOpen: Bool
    private let firstWhyOpen: Bool

    init(model: UserModelViewModel, open: @escaping (RecallRoute) -> Void, items: [WorkItem] = []) {
        self.init(model: model, open: open, items: items, keptBackOpen: false, notSeenOpen: false,
                  firstWhyOpen: false)
    }

    /// The renderer draws the closed sections open.
    init(model: UserModelViewModel, open: @escaping (RecallRoute) -> Void, items: [WorkItem] = [],
         keptBackOpen: Bool, notSeenOpen: Bool, firstWhyOpen: Bool) {
        self.model = model
        self.open = open
        self.items = items
        _keptBackOpen = State(initialValue: keptBackOpen)
        _notSeenOpen = State(initialValue: notSeenOpen)
        self.firstWhyOpen = firstWhyOpen
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                content
            }
            // Where every page starts, as Working On lays out (the
            // prototype's About You).
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(MCI.Color.background)
        .task { await model.reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: UserFacingCopy.You.title)
                .font(MCI.Font.title)
                .foregroundStyle(MCI.Color.foreground)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: UserFacingCopy.You.lead)
                .font(.system(size: 13))
                .foregroundStyle(MCI.Color.foregroundSecondary)
            // Lines no AI tool is given yet are listed with the rest, each
            // saying so; this says once what that means.
            if model.state == .ready, model.hasLinesNotSentYet {
                Text(verbatim: UserFacingCopy.You.notSentLine)
                    .font(.system(size: 13))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().controlSize(.small)
                .padding(.vertical, 24)
        case .unavailable:
            VStack(alignment: .leading, spacing: 10) {
                Text(UserFacingCopy.You.unavailableTitle)
                    .font(MCI.Font.body)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                Button(UserFacingCopy.Overview.tryAgain) { Task { await model.reload() } }
                    .buttonStyle(.bordered)
            }
        case .nothingLearned, .needsModel:
            OverviewCard(padding: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(UserFacingCopy.You.nothingLearnedTitle)
                        .font(MCI.Font.title2)
                        .foregroundStyle(MCI.Color.foreground)
                    Text(model.state == .needsModel
                         ? UserFacingCopy.You.modelLine(model.page?.modelStatus.unavailableReason ?? .notAvailable)
                         : UserFacingCopy.You.nothingLearnedBody)
                        .font(.system(size: 14))
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .ready:
            if let page = model.page {
                VStack(alignment: .leading, spacing: 24) {
                    shared
                    bottomRow(page)
                    footer(page)
                }
            }
        }
    }

    // MARK: What your AI can be told about you

    private var shared: some View {
        let shared = model.groups(.shared)
        return VStack(alignment: .leading, spacing: 24) {
            if shared.isEmpty {
                // Early on, everything learned may still be below the bar.
                Text(UserFacingCopy.You.sharedEmpty)
                    .font(MCI.Font.body)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
            }
            if model.verdictFailed {
                Text(UserFacingCopy.verdictNotSaved)
                    .font(MCI.Font.caption)
                    .foregroundStyle(MCI.Color.error)
            }
            groups(shared, openFirstWhy: firstWhyOpen)
        }
    }

    private func groups(_ groups: [ModelItemGroup], openFirstWhy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                VStack(alignment: .leading, spacing: 4) {
                    if let title = group.title {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(MCI.Color.foreground)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.bottom, 4)
                    }
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { rowIndex, row in
                        if rowIndex > 0 { Divider() }
                        YouItemRow(row: row, model: model, open: open,
                                   whyOpen: openFirstWhy && groupIndex == 0 && rowIndex == 1,
                                   item: UserModelGrouping.item(named: row.item.text, among: items))
                    }
                    Divider()
                }
            }
        }
    }

    // MARK: The bottom row

    /// "Not sent unless your AI looks it up · Not seen lately · Names You
    /// Use…", the first two opening their lines below.
    @ViewBuilder
    private func bottomRow(_ page: ModelPage) -> some View {
        let keptBack = model.groups(.keptBack)
        let notSeen = model.groups(.notSeenLately)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                if !keptBack.isEmpty {
                    DisclosureLink(title: UserFacingCopy.You.keptBackTitle, isOpen: $keptBackOpen)
                    Text(verbatim: "\u{00B7}").foregroundStyle(MCI.Color.foregroundMuted)
                }
                if !notSeen.isEmpty {
                    DisclosureLink(title: UserFacingCopy.You.notSeenLatelyTitle, isOpen: $notSeenOpen)
                    Text(verbatim: "\u{00B7}").foregroundStyle(MCI.Color.foregroundMuted)
                }
                Button(UserFacingCopy.You.namesYouUse) { open(.names) }
                    .buttonStyle(.plain)
                    .foregroundStyle(MCI.Color.accent)
            }
            .font(.system(size: 13))
            if keptBackOpen, !keptBack.isEmpty {
                openList(UserFacingCopy.You.keptBackTitle, keptBack)
            }
            if notSeenOpen, !notSeen.isEmpty {
                openList(UserFacingCopy.You.notSeenLatelyTitle, notSeen)
            }
        }
    }

    /// One of the bottom row's lists, opened, under its name.
    private func openList(_ title: String, _ list: [ModelItemGroup]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title)
                .font(MCI.Font.caption)
                .foregroundStyle(MCI.Color.foregroundSecondary)
            groups(list, openFirstWhy: false)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func footer(_ page: ModelPage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.modelIsOff, let reason = page.modelStatus.unavailableReason {
                Text(UserFacingCopy.You.modelLine(reason))
            } else if page.modelStatus.state == .available {
                Text(UserFacingCopy.You.writtenByAppleIntelligence)
            }
        }
        .font(MCI.Font.caption)
        .foregroundStyle(MCI.Color.foregroundSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// You's old name: the shell still opens it so.
typealias YouPlace = AboutYouPlace

/// A quiet disclosure in a row of links: its title and a chevron that turns.
private struct DisclosureLink: View {
    let title: String
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            withAnimation(MCI.Motion.snap) { isOpen.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .accessibilityHidden(true)
                Text(verbatim: title)
            }
            .foregroundStyle(MCI.Color.foreground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
    }
}
