// HitRow.swift — one row in the recall search/timeline lists.
//
// Cycle 8.36 PR-2 (docs/research/2026-07-12-recall-ui-audit.md §5, §7):
// surfaces the entity chips + plain-English match-reason label that
// unblock the "WOW moment" now that PR #27 has plumbed entities +
// linked_event_ids end-to-end. Chip taps DO NOT open the flyout — that
// wiring lives in PR-3 (`RelatedHitsFlyout` in `DetailPaneView`).
//
// Keyframes use the shared authenticated `EvidenceThumbnail` renderer.
// Invalid, missing, escaped, oversized, or tampered blobs fail closed to
// a neutral placeholder rather than being opened directly by AppKit.

import RecallUIKit
import SwiftUI

struct HitRow: View {
    let hit: Hit
    /// History shows the clock time ("2:14 PM"); matches show how long ago.
    var showsClockTime = false
    /// Moments in a row from the same window, shown as one row.
    var count = 1

    private var title: String {
        if let title = hit.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let url = hit.url, !url.isEmpty { return url }
        return Formatters.appDisplayName(hit.appBundleId)
    }

    /// One line of what the window said, without the stored header or a
    /// first line that only repeats the title.
    private var line: String {
        Formatters.rowLine(hit.ocrTextSnippet, title: hit.windowTitle, maxLen: 160)
    }

    /// History has the day above it, so a row shows the clock time; a match
    /// can be from any day ("Oct 12, 2:36 PM").
    private var when: String {
        showsClockTime
            ? Formatters.clockTime(us: Int64(clamping: hit.tsUs))
            : Formatters.dayAndTime(us: hit.tsUs)
    }

    /// Only a match by meaning says how it matched: an exact-words match
    /// already shows the words, and History is not a search.
    private var reason: String? {
        guard !showsClockTime, hit.source != "lexical" else { return nil }
        return Formatters.matchReason(hit.source)
    }

    /// "Safari · Web page", and how many moments the row holds.
    private var origin: String {
        let source = "\(Formatters.appDisplayName(hit.appBundleId)) \u{00B7} "
            + UserFacingCopy.momentSource(sourceKind: hit.sourceKind)
        return count > 1 ? "\(source), \(UserFacingCopy.momentCount(count))" : source
    }

    var body: some View {
        // Spacing tokens (cycle 8.48 MCIDesignSystem): row internal
        // rhythm is on the 8pt grid.
        HStack(alignment: .top, spacing: MCI.Spacing.m - 2) {
            EvidenceThumbnail(
                url: hit.thumbnailURL,
                size: CGSize(width: 64, height: 40),
                maxPixelSize: 160
            )
            VStack(alignment: .leading, spacing: MCI.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: MCI.Spacing.s) {
                    Text(verbatim: title)
                        .mciFont(.bodyStrong)
                        .foregroundStyle(Color.brandFgPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(verbatim: when)
                        .mciFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.brandFgSecondary)
                        .help(Formatters.dayAndTime(us: hit.tsUs))
                }
                if !line.isEmpty {
                    Text(verbatim: line)
                        .mciFont(.body)
                        .foregroundStyle(Color.brandFgSecondary)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: MCI.Spacing.s) {
                    Text(verbatim: origin)
                        .font(.caption)
                        .foregroundStyle(Color.brandFgMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let reason {
                        Text(reason)
                            .font(MCI.Font.footnote)
                            .foregroundStyle(Color.brandFgMuted)
                            .lineLimit(1)
                            .accessibilityLabel(reason)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, MCI.Spacing.s - 2)
    }
}

/// Horizontal strip of entity name chips with a "+N more" overflow
/// affordance. Uniform styling (mint-outline) — the FFI carries entity
/// names as `[String]` only (PR #27), no per-entity `kind`, so a
/// color-by-kind pass has to wait on an FFI extension.
///
/// Accessibility: each chip carries the entity name as its label;
/// overflow chip announces the hidden count.
struct EntityChipStrip: View {
    let entities: [String]

    var body: some View {
        let disp = Formatters.entityChipDisplay(entities)
        HStack(spacing: 4) {
            ForEach(Array(disp.visible.enumerated()), id: \.offset) { _, name in
                EntityChip(label: name)
            }
            if disp.overflow > 0 {
                EntityChip(label: "+\(disp.overflow) more", isOverflow: true)
                    .accessibilityLabel(UserFacingCopy.moreNames(disp.overflow))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            entities.isEmpty ? "" : UserFacingCopy.names(entities)
        )
    }
}

/// Single compact chip. A subtly dimmer palette
/// distinguishes the overflow chip from real entity names.
struct EntityChip: View {
    let label: String
    var isOverflow: Bool = false

    var body: some View {
        Text(label)
            .font(.system(.caption2, design: .default))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(
                isOverflow ? Color.brandFgMuted : Color.brandMint
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: MCI.Radius.xs, style: .continuous)
                    .fill(Color.brandMintSubtle.opacity(isOverflow ? 0.4 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MCI.Radius.xs, style: .continuous)
                    .stroke(
                        isOverflow ? Color.brandCardBorder : Color.brandMintDim,
                        lineWidth: 0.5
                    )
            )
    }
}

/// Small link icon + "N related" caption. PR-3 wires the tap-to-flyout;
/// this PR renders the affordance without interaction so the WOW visual
/// lands on real data as soon as the FFI ships events with edges.
struct LinkedEventsBadge: View {
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "link")
                .font(.system(.caption2))
            Text(label)
                .font(.system(.caption2, design: .default))
        }
        .foregroundStyle(Color.brandMintDim)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: MCI.Radius.xs, style: .continuous)
                .stroke(Color.brandMintDim, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

// MARK: - Previews
//
// Four cases per audit-doc §5 PR-2 spec, stacked in one preview:
// (1) zero-entity backward-compat control, (2) 3 entities chips-only,
// (3) 3 entities + 2 linked (chips + badge), (4) 7 entities + 5 linked
// overflow. Rendered on the brand background so mint-on-dark matches
// the shipping visual.

#if DEBUG && canImport(PreviewsMacros)
    private func previewHit(
        id: UInt64,
        title: String,
        source: String = "hybrid",
        entities: [String] = [],
        linked: [UInt64] = [],
        thumbnailPath: String? = nil
    ) -> Hit {
        Hit(
            eventId: id, tsUs: 1_736_000_000_000_000,
            appBundleId: "com.apple.Safari", windowTitle: title,
            url: "https://example.org/",
            ocrTextSnippet: "Vector databases at scale: a survey of ANN methods.",
            source: source, score: 0.74,
            entities: entities, linkedEventIds: linked,
            thumbnailPath: thumbnailPath
        )
    }

    #Preview("HitRow cases") {
        VStack(alignment: .leading, spacing: 12) {
            // (1) Backward-compat: no thumbnail, no entities.
            HitRow(hit: previewHit(id: 1, title: "Apple — Privacy", source: "lexical"))
            // (2) Chips only, no thumbnail (nil URL → placeholder icon).
            HitRow(hit: previewHit(
                id: 2, title: "arxiv.org/abs/2312",
                entities: ["vector-db", "Anthropic", "embedding"]))
            // (3) Chips + linked-events badge + a broken thumbnail path.
            // Broken URL still renders the placeholder — this is the
            // "user deleted the blobs dir out of band" case.
            HitRow(hit: previewHit(
                id: 3, title: "retriever.rs — mci",
                entities: ["sqlite-vec", "retriever", "MCI"],
                linked: [101, 102],
                thumbnailPath: "/tmp/nonexistent-mci-blob.bin"))
            // (4) Overflow chips + linked flyout badge (no thumbnail).
            HitRow(hit: previewHit(
                id: 4, title: "#eng-brain — Slack",
                entities: ["MCI", "Anthropic", "sqlite-vec", "embedding",
                    "retriever", "vector-db", "MCP"],
                linked: [201, 202, 203, 204, 205]))
            // (5) "Very tall thumbnail" case — the .aspectRatio(.fill) +
            // fixed-size frame + .clipped() combo means a portrait
            // thumbnail gets center-cropped to 64x40 rather than
            // stretched. This preview asserts the row height doesn't
            // wobble when the source aspect ratio is unexpected.
            HitRow(hit: previewHit(
                id: 5, title: "portrait screenshot",
                thumbnailPath: "/tmp/nonexistent-portrait-mci-blob.bin"))
        }
        .padding()
        .background(Color.brandBgPrimary)
    }
#endif
