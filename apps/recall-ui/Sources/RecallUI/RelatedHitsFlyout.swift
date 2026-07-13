// RelatedHitsFlyout.swift — cycle 8.37 PR-3, the **visible dot-connect
// moment** in the recall UI.
//
// When the user (a) long-hovers or clicks an entity chip on the currently
// selected hit's detail pane, or (b) clicks the "🔗 N related" badge next
// to the detail-pane header, this popover fetches the linked-sibling
// events via `BrainReader.fetchEventsByIds(...)` and renders one row per
// sibling: app icon · brief context · relative time. That is the
// concrete answer to "your Safari tab about vector databases is
// connected to your Slack message and your VSCode buffer from the same
// week" — the personal-memory pitch made visible.
//
// The audit doc for this surface is
// `docs/research/2026-07-12-recall-ui-audit.md` §"Recommended polish
// sequence" (PR-3). PR-1 (#27) plumbed `linkedEventIds` through the FFI;
// PR-2 (parallel worktree, this cycle) renders the entity chip strip on
// `HitRow`. This PR is the third leg — the fetch surface + the flyout
// view. This file explicitly does NOT modify `HitRow.swift` (that is
// PR-2's territory); the flyout mounts inside `DetailPaneView` where
// PR-3's scope lives per §5 of the audit.

import RecallUIKit
import SwiftUI

/// Which set of linked events the flyout is scoped to when the user
/// opens it. Carried as state so the header + fetch stay in sync.
enum RelatedHitsScope: Equatable {
    /// Triggered from the "🔗 N related" badge on the detail pane —
    /// shows every event in `hit.linkedEventIds`. Header: "Cross-app
    /// connections".
    case all(hitId: UInt64)
    /// Triggered from a specific entity chip (long-hover ~500 ms OR
    /// click). Shows the same linked-event set (the data model doesn't
    /// currently partition linked ids per entity — see PR-3 scope note
    /// in the audit doc §5), but the header reads "Related to
    /// [entity]" so the user understands why the connections exist.
    case entity(hitId: UInt64, name: String)

    var headerText: String {
        switch self {
        case .all: return "Cross-app connections"
        case .entity(_, let name): return "Related to \(name)"
        }
    }

    var sourceHitId: UInt64 {
        switch self {
        case .all(let id): return id
        case .entity(let id, _): return id
        }
    }
}

/// The popover body itself — kept view-only so the caller (a
/// `DetailPaneView` popover host) owns lifecycle + dismissal.
struct RelatedHitsFlyout: View {
    /// The hit whose siblings we are showing. The flyout reads
    /// `hit.linkedEventIds` and passes it to the reader.
    let hit: Hit
    /// Why the flyout was opened — controls the header text.
    let scope: RelatedHitsScope
    /// Injected reader — `StubBrainReader` in previews / tests,
    /// `FFIBrainReader` in the shipped app.
    let reader: BrainReader
    /// Bubble up a click on one of the rendered rows so the parent view
    /// can push it into the selection. `nil` when the flyout is
    /// read-only (previews).
    var onSelect: ((Hit) -> Void)?
    /// Bubble up a dismissal — used for click-outside + ESC.
    var onDismiss: () -> Void

    @State private var loadState: LoadState = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.brandCardBorder)
            content
        }
        .frame(width: 320)
        .frame(maxHeight: 320)
        .background(Color.brandBgElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.brandCardBorder, lineWidth: 1)
        )
        .cornerRadius(6)
        .task(id: hit.eventId) { await load() }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .foregroundStyle(Color.brandMint)
                .font(.system(.caption, design: .default))
            Text(scope.headerText)
                .font(.system(.caption, design: .default).weight(.semibold))
                .foregroundStyle(Color.brandFgPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if case .loaded(let hits) = loadState, !hits.isEmpty {
                Text("\(hits.count)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.brandFgMuted)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Resolving links…")
                    .font(.caption)
                    .foregroundStyle(Color.brandFgMuted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .center)
        case .failed(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(Color.brandFgMuted)
                .padding(12)
        case .loaded(let hits) where hits.isEmpty:
            // Cycle 8.49 polished empty state (audit-gap fix). Scaled
            // to fit the flyout's fixed 320pt width envelope.
            MCIEmptyState.noRelatedHits()
                .padding(.vertical, MCI.Spacing.s)
        case .loaded(let hits):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hits) { linked in
                        RelatedHitRow(hit: linked)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect?(linked)
                                onDismiss()
                            }
                        Divider().background(Color.brandCardBorder.opacity(0.5))
                    }
                }
            }
        }
    }

    private func load() async {
        loadState = .loading
        // Filter out self-references defensively — the FFI drops missing
        // ids but shouldn't include the source hit in the first place;
        // this is a UX safety net.
        let ids = hit.linkedEventIds.filter { $0 != hit.eventId }
        guard !ids.isEmpty else {
            loadState = .loaded([])
            return
        }
        do {
            let hits = try await reader.fetchEventsByIds(ids)
            loadState = .loaded(hits)
        } catch {
            loadState = .failed("\(error)")
        }
    }

    enum LoadState: Equatable {
        case loading
        case failed(String)
        case loaded([Hit])
    }
}

/// One row inside the flyout — app · time · brief snippet. Trimmed
/// tighter than `HitRow` because the popover is width-constrained.
private struct RelatedHitRow: View {
    let hit: Hit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(appShortName(hit.appBundleId))
                    .font(.system(.caption, design: .default).weight(.semibold))
                    .foregroundStyle(Color.brandFgPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Formatters.relativeTime(usSinceEpoch: hit.tsUs))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.brandMint)
                    .help(Formatters.tsString(usSinceEpoch: hit.tsUs))
            }
            Text(Formatters.snippet(
                Formatters.stripContextHeader(hit.ocrTextSnippet),
                maxLen: 100
            ))
            .font(.system(.caption, design: .default))
            .foregroundStyle(Color.brandFgSecondary)
            .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Trim `com.foo.Bar` → `Bar` so the width-constrained flyout row
    /// stays readable. Falls back to "(no app)" on nil.
    private func appShortName(_ bundleId: String?) -> String {
        guard let bid = bundleId, !bid.isEmpty else { return "(no app)" }
        return bid.split(separator: ".").last.map(String.init) ?? bid
    }
}

// ---------------------------------------------------------------------------
// SwiftUI previews — visual states the flyout renders. Wire a
// `StubBrainReader` so the previews resolve linked ids against the demo
// corpus without touching the FFI.
// ---------------------------------------------------------------------------

#Preview("Loaded — cross-app connections (all)") {
    let reader = StubBrainReader()
    // Hit 102 in the demo corpus links to 101 + 103 (audit §7 topology).
    let hit = StubBrainReader.demoHits.first { $0.eventId == 102 }!
    return RelatedHitsFlyout(
        hit: hit,
        scope: .all(hitId: hit.eventId),
        reader: reader,
        onDismiss: {}
    )
    .padding()
    .background(Color.brandBgPrimary)
}

#Preview("Loaded — scoped to entity chip (long-hover)") {
    let reader = StubBrainReader()
    let hit = StubBrainReader.demoHits.first { $0.eventId == 102 }!
    return RelatedHitsFlyout(
        hit: hit,
        scope: .entity(hitId: hit.eventId, name: "MCI"),
        reader: reader,
        onDismiss: {}
    )
    .padding()
    .background(Color.brandBgPrimary)
}

#Preview("Empty — hit with no siblings") {
    let reader = StubBrainReader()
    // Fake a hit with an empty linkedEventIds so we exercise the empty branch.
    let hit = Hit(
        eventId: 999,
        tsUs: 1_736_000_000_000_000,
        appBundleId: "com.apple.Safari",
        windowTitle: "Standalone page",
        url: nil,
        ocrTextSnippet: "no siblings",
        source: "lexical",
        score: 0.5,
        entities: ["Standalone"],
        linkedEventIds: []
    )
    return RelatedHitsFlyout(
        hit: hit,
        scope: .all(hitId: hit.eventId),
        reader: reader,
        onDismiss: {}
    )
    .padding()
    .background(Color.brandBgPrimary)
}
