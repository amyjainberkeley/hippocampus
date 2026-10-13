import RecallUIKit
import SwiftUI

/// You: what Hippocampus tells your AI about you, in the exact words sent,
/// for you to correct (RULINGS I7, I8, I10; contract model-page.md).
///
/// "Recent work" first, as a connected AI is given it; then "What your AI can
/// be told about you" with Right and Forget on each item; then, closed, what
/// is sent only when an AI looks it up and what has not been seen lately; then
/// "Your data". The numbers in the captions come from `WhatIsSent`.
///
/// The shell owns the model (built with the verdict inbox) and the page's
/// navigation: the "Your data" rows and a session row each call `open` with
/// a route (`.you` with `[.privacy]` or `[.names]`, or a session on
/// Overview). See `work/contract/places.md`.
struct YouPlace: View {
    @ObservedObject var model: UserModelViewModel
    let open: (RecallRoute) -> Void

    @State private var keptBackOpen: Bool
    @State private var notSeenOpen: Bool
    private let firstWhyOpen: Bool
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview

    init(model: UserModelViewModel, open: @escaping (RecallRoute) -> Void) {
        self.init(model: model, open: open, keptBackOpen: false, notSeenOpen: false, firstWhyOpen: false)
    }

    /// The renderer draws the closed sections open.
    init(model: UserModelViewModel, open: @escaping (RecallRoute) -> Void,
         keptBackOpen: Bool, notSeenOpen: Bool, firstWhyOpen: Bool) {
        self.model = model
        self.open = open
        _keptBackOpen = State(initialValue: keptBackOpen)
        _notSeenOpen = State(initialValue: notSeenOpen)
        self.firstWhyOpen = firstWhyOpen
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                content
                yourData
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(MCI.Color.background)
        .task { await model.reload() }
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
            VStack(alignment: .leading, spacing: 32) {
                if let page = model.page, !page.recentWork.isEmpty {
                    recentWork(page)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(UserFacingCopy.You.nothingLearnedTitle)
                        .font(MCI.Font.title2)
                        .foregroundStyle(MCI.Color.foreground)
                    Text(model.state == .needsModel
                         ? UserFacingCopy.You.modelLine(model.page?.modelStatus.unavailableReason ?? .notAvailable)
                         : UserFacingCopy.You.nothingLearnedBody)
                        .font(MCI.Font.body)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .ready:
            if let page = model.page {
                VStack(alignment: .leading, spacing: 32) {
                    recentWork(page)
                    shared
                    lookUpOnly(page)
                    footer(page)
                }
            }
        }
    }

    // MARK: Recent work

    private func recentWork(_ page: ModelPage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(UserFacingCopy.You.recentWorkTitle,
                         caption: UserFacingCopy.You.recentWorkCaption)
            if page.recentWork.isEmpty {
                Text(UserFacingCopy.You.recentWorkEmpty)
                    .font(MCI.Font.body)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
            } else {
                OverviewCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(page.recentWork.enumerated()), id: \.offset) { _, line in
                            SentLine(text: line.text(locale: locale, timeZone: timeZone))
                        }
                    }
                }
            }
        }
    }

    // MARK: What your AI can be told about you

    private var shared: some View {
        let shared = model.groups(.shared)
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(UserFacingCopy.You.sharedTitle, caption: UserFacingCopy.You.sharedCaption)
            if shared.isEmpty {
                // Early on, everything learned may still be below the bar.
                Text(UserFacingCopy.You.sharedEmpty)
                    .font(MCI.Font.body)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
            } else {
                Text(UserFacingCopy.You.exactWords)
                    .font(MCI.Font.caption)
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

    @ViewBuilder
    private func lookUpOnly(_ page: ModelPage) -> some View {
        let keptBack = model.groups(.keptBack)
        if !keptBack.isEmpty {
            DisclosureGroup(isExpanded: $keptBackOpen) {
                groups(keptBack, openFirstWhy: false)
                    .padding(.top, 8)
            } label: {
                Text(UserFacingCopy.You.keptBackTitle)
                    .font(MCI.Font.bodyStrong)
                    .foregroundStyle(MCI.Color.foreground)
            }
        }
        let notSeen = model.groups(.notSeenLately)
        if !notSeen.isEmpty {
            DisclosureGroup(isExpanded: $notSeenOpen) {
                groups(notSeen, openFirstWhy: false)
                    .padding(.top, 8)
            } label: {
                Text(UserFacingCopy.You.notSeenLatelyTitle)
                    .font(MCI.Font.bodyStrong)
                    .foregroundStyle(MCI.Color.foreground)
            }
        }
    }

    private func groups(_ groups: [ModelItemGroup], openFirstWhy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                VStack(alignment: .leading, spacing: 0) {
                    if let title = group.title {
                        Text(title)
                            .font(MCI.Font.caption)
                            .foregroundStyle(MCI.Color.foregroundMuted)
                            .padding(.bottom, 2)
                    }
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { rowIndex, row in
                        if rowIndex > 0 { Divider() }
                        YouItemRow(row: row, model: model, open: open,
                                   whyOpen: openFirstWhy && groupIndex == 0 && rowIndex == 0)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func footer(_ page: ModelPage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(UserFacingCopy.You.footer)
            if model.modelIsOff, let reason = page.modelStatus.unavailableReason {
                Text(UserFacingCopy.You.modelLine(reason))
            }
        }
        .font(MCI.Font.caption)
        .foregroundStyle(MCI.Color.foregroundSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Your data

    private var yourData: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(UserFacingCopy.You.yourDataTitle)
            OverviewCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    DataRow(title: UserFacingCopy.You.rememberedRow,
                            caption: UserFacingCopy.You.rememberedCaption) {
                        open(RecallRoute(place: .you, youPath: [.privacy]))
                    }
                    Divider().padding(.leading, 16)
                    DataRow(title: UserFacingCopy.You.namesRow) {
                        open(RecallRoute(place: .you, youPath: [.names]))
                    }
                    Divider().padding(.leading, 16)
                    DataRow(title: UserFacingCopy.You.aiToolsRow) { openAITools() }
                }
            }
            .disabled(isSyntheticPreview)
        }
    }
}

/// A section's title, with an optional caption under it.
private struct SectionTitle: View {
    let title: String
    let caption: String?

    init(_ title: String, caption: String? = nil) {
        self.title = title
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(MCI.Font.title2)
                .foregroundStyle(MCI.Color.foreground)
            if let caption {
                Text(caption)
                    .font(MCI.Font.caption)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row of "Your data" that opens a page or a pane.
private struct DataRow: View {
    let title: String
    var caption: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(MCI.Font.body)
                        .foregroundStyle(isEnabled ? MCI.Color.foreground : MCI.Color.foregroundMuted)
                    if let caption {
                        Text(caption)
                            .font(MCI.Font.caption)
                            .foregroundStyle(MCI.Color.foregroundSecondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(MCI.Font.caption)
                    .foregroundStyle(MCI.Color.foregroundMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
