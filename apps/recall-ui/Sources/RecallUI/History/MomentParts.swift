import AppKit
import RecallUIKit
import SwiftUI

// The parts History and its lenses share (SPEC 3.4, SPEC-DELTA 1): a row's
// menu, the detail for several rows, the trash button, an hour heading with
// its Forget, and the line at the end of what is kept.

/// The quiet trash button at the far right of a detail's actions. Its
/// tooltip says what it forgets and its key.
struct TrashButton: View {
    let help: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 13))
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(LibraryCopy.History.forgetHint)
    }
}

/// "Copy for Your AI" for several moments: their Markdown on the clipboard,
/// "Copied" for two seconds, and a line when it couldn't.
struct CopyMomentsForAIButton: View {
    let ids: [UInt64]
    let reader: BrainReader

    private enum Phase { case idle, copying, copied, failed }
    @State private var phase: Phase = .idle
    @Environment(\.handoffServices) private var handoff
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview

    var body: some View {
        HStack(spacing: 8) {
            Button(phase == .copied ? UserFacingCopy.Overview.copied : LibraryCopy.History.copyForYourAI) {
                Task { await copy() }
            }
            .buttonStyle(.bordered)
            .tint(Color.brandMint)
            .disabled(phase == .copying)
            if phase == .failed {
                Text(UserFacingCopy.Overview.couldNotCopy)
                    .font(MCI.Font.caption)
                    .foregroundStyle(MCI.Color.error)
            }
        }
    }

    private func copy() async {
        phase = .copying
        // The builder's message, by the clipboard rules (SPEC 5.3.6).
        let services = HandoffServices.resolved(handoff, isSyntheticPreview: isSyntheticPreview)
        guard await AskAIButton.copyForYourAI(.moments(ids), services: services) else {
            phase = .failed
            return
        }
        phase = .copied
        try? await Task.sleep(for: .seconds(2))
        if phase == .copied { phase = .idle }
    }
}

/// The clipboard, as a moment's actions use it.
enum MomentClipboard {
    @discardableResult
    static func put(_ text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
    }
}

/// The detail when several rows are picked (SPEC 3.4): how many moments,
/// what they were about, Ask, Copy for Your AI, the trash, and their
/// pictures.
struct MultiMomentDetail: View {
    let selection: MomentSelection
    let reader: BrainReader?

    @Environment(\.forget) private var forget

    /// The pictures at a row's size: 120 by 75 points, the screen's shape.
    private static let picture = CGSize(width: 120, height: 75)
    private let columns = [GridItem(.adaptive(minimum: picture.width, maximum: picture.width), spacing: MCI.Spacing.s)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MCI.Spacing.l) {
                VStack(alignment: .leading, spacing: MCI.Spacing.s) {
                    Text(verbatim: LibraryCopy.History.selected(selection.momentCount))
                        .mciFont(.title2)
                        .foregroundStyle(Color.brandFgPrimary)
                    Text(verbatim: selection.captions.joined(separator: " \u{00B7} "))
                        .font(.body)
                        .foregroundStyle(Color.brandFgSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if let reader {
                        AskAIButton(source: .moments(selection.momentIds), reader: reader,
                                    handlesCommandReturn: true)
                            .controlSize(.small)
                        CopyMomentsForAIButton(ids: selection.momentIds, reader: reader)
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                    if let forget {
                        TrashButton(help: LibraryCopy.History.forgetHelp(selection.momentCount),
                                    label: LibraryCopy.History.forgetMoments(selection.momentCount)) {
                            forget(.moments(selection.momentIds))
                        }
                    }
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: MCI.Spacing.s) {
                    ForEach(selection.pictures) { hit in
                        EvidenceThumbnail(url: hit.thumbnailURL, appBundleId: hit.appBundleId,
                                          size: Self.picture, maxPixelSize: 320,
                                          contentMode: .fill, alignment: .top)
                            .accessibilityLabel(MomentRowText.headline(hit))
                    }
                }
            }
            .padding(MCI.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LibraryCopy.History.selected(selection.momentCount))
    }
}

/// An hour's heading over its rows ("2 PM"), whose menu forgets the hour.
struct HourHeading: View {
    let title: String
    /// "Forget 2 PM to 3 PM…", when forgetting is offered.
    var forgetTitle: String?
    var forgetHour: (() -> Void)?

    var body: some View {
        Text(verbatim: title)
            .mciFont(.caption)
            .foregroundStyle(Color.brandFgSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                if let forgetTitle, let forgetHour {
                    Button(forgetTitle, role: .destructive, action: forgetHour)
                }
            }
    }
}

/// The end of the list at the oldest day kept: "Older moments are deleted
/// after 90 days." [Change…] (SPEC 3.4).
struct RetentionLine: View {
    let days: Int
    let change: () -> Void

    var body: some View {
        HStack(spacing: MCI.Spacing.s) {
            Text(verbatim: LibraryCopy.olderDeleted(days: days))
                .font(MCI.Font.caption)
                .foregroundStyle(MCI.Color.foregroundSecondary)
            Button(LibraryCopy.change, action: change)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MCI.Spacing.l)
    }
}

/// What a row's menu does, for History and every lens (SPEC 3.4): Open,
/// Copy Text, Open Link, Open Screenshot, Copy for Your AI, Show Related and
/// Forget. The rows it acts on are the clicked one, or every picked row when
/// the clicked one is picked.
struct MomentMenu: View {
    let picked: MomentSelection
    let reader: BrainReader?
    let open: () -> Void
    let openScreenshot: (Hit) -> Void
    let showRelated: (Hit) -> Void

    @Environment(\.forget) private var forget
    @Environment(\.handoffServices) private var handoff
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview

    private var single: HistoryRow? { picked.rows.count == 1 ? picked.rows[0] : nil }

    var body: some View {
        if !picked.isEmpty {
            Button(LibraryCopy.History.open, action: open)
            Button(LibraryCopy.History.copyText) { MomentRowActions.copyText(picked, reader: reader) }
                .keyboardShortcut("c", modifiers: .command)
            if let url = MomentRowActions.link(picked) {
                Button(LibraryCopy.History.openLink) { NSWorkspace.shared.open(url) }
                    .keyboardShortcut("o", modifiers: .command)
            }
            if let row = single, let shot = row.screenshot {
                Button(LibraryCopy.History.openScreenshot) { openScreenshot(shot) }
                    .keyboardShortcut(.space, modifiers: [])
            }
            if let reader {
                Divider()
                let ids = picked.momentIds
                // Ask Claude ▸, the tools on this Mac (SPEC 5.3.1).
                AskAIMenu(source: .moments(ids))
                Button(LibraryCopy.History.copyForYourAI) {
                    let services = HandoffServices.resolved(handoff, isSyntheticPreview: isSyntheticPreview)
                    MomentRowActions.copyForYourAI(ids, services: services)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                if let hit = MomentRowActions.related(picked) {
                    Button(LibraryCopy.History.showRelated) { showRelated(hit) }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }
            if let forget {
                Divider()
                Button(LibraryCopy.History.forgetMomentsMenu(picked.momentCount), role: .destructive) {
                    forget(.moments(picked.momentIds))
                }
            }
        }
    }
}

/// What a row's menu does, so the list's own keys do exactly the same
/// (SPEC 2.10): Copy Text, Open Link, Copy for Your AI and Show Related.
@MainActor
enum MomentRowActions {
    /// Copy Text: each picked moment's text as the detail shows it, one
    /// after another.
    static func copyText(_ picked: MomentSelection, reader: BrainReader?) {
        let hits = picked.rows.map(\.hit)
        Task {
            var texts: [String] = []
            for hit in hits { texts.append(await MomentActions.text(of: hit, reader: reader)) }
            MomentClipboard.put(texts.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
    }

    /// The page Open Link opens: the one picked moment's, when it has one.
    static func link(_ picked: MomentSelection) -> URL? {
        picked.rows.count == 1 ? MomentActions.link(of: picked.rows[0].hit) : nil
    }

    /// Copy for Your AI: the builder's message for the moments, by the
    /// clipboard rules (SPEC 5.3.6).
    static func copyForYourAI(_ ids: [UInt64], services: HandoffServices) {
        Task { await AskAIButton.copyForYourAI(.moments(ids), services: services) }
    }

    /// The moment Show Related opens: the one picked, when it has related
    /// moments.
    static func related(_ picked: MomentSelection) -> Hit? {
        guard picked.rows.count == 1, !picked.rows[0].hit.linkedEventIds.isEmpty else { return nil }
        return picked.rows[0].hit
    }
}

/// The row menu's keys on the list itself (SPEC 2.10): ⌘C Copy Text, ⇧⌘C
/// Copy for Your AI, ⌘O Open Link and ⇧⌘R Show Related act on the rows
/// picked while the list has the keyboard. ⌘C is the window's own key only
/// then, ahead of Edit › Copy, so ⌘C in the field or in a detail's text
/// still copies the words picked there.
struct MomentRowKeys: ViewModifier {
    let picked: MomentSelection
    let reader: BrainReader?
    let showRelated: (Hit) -> Void

    @FocusState private var listFocused: Bool
    @Environment(\.handoffServices) private var handoff
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview

    func body(content: Content) -> some View {
        content
            .focused($listFocused)
            .background {
                if listFocused, !picked.isEmpty {
                    Button("") { perform(.copyText) }
                        .keyboardShortcut("c", modifiers: .command)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .onKeyPress(phases: .down) { press in
                guard let key = MomentKey(character: press.key.character, modifiers: press.modifiers),
                      key != .copyText
                else { return .ignored }
                return perform(key) ? .handled : .ignored
            }
    }

    /// What the row's menu item for `key` does; false when it offers none.
    @discardableResult
    private func perform(_ key: MomentKey) -> Bool {
        guard !picked.isEmpty else { return false }
        switch key {
        case .copyText:
            MomentRowActions.copyText(picked, reader: reader)
        case .copyForYourAI:
            guard reader != nil else { return false }
            let services = HandoffServices.resolved(handoff, isSyntheticPreview: isSyntheticPreview)
            MomentRowActions.copyForYourAI(picked.momentIds, services: services)
        case .openLink:
            guard let url = MomentRowActions.link(picked) else { return false }
            NSWorkspace.shared.open(url)
        case .showRelated:
            guard reader != nil, let hit = MomentRowActions.related(picked) else { return false }
            showRelated(hit)
        }
        return true
    }
}
