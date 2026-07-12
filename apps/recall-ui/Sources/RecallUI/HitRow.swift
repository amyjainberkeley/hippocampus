// HitRow.swift — one row in the recall search/timeline lists.
//
// Cycle 8.36 PR-2 (docs/research/2026-07-12-recall-ui-audit.md §5, §7):
// surfaces the entity chips + plain-English match-reason label that
// unblock the "WOW moment" now that PR #27 has plumbed entities +
// linked_event_ids end-to-end. Chip taps DO NOT open the flyout — that
// wiring lives in PR-3 (`RelatedHitsFlyout` in `DetailPaneView`).

import RecallUIKit
import SwiftUI

struct HitRow: View {
    let hit: Hit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Formatters.relativeTime(usSinceEpoch: hit.tsUs))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.brandMint)
                    .help(Formatters.tsString(usSinceEpoch: hit.tsUs))
                Text(Formatters.contextLine(hit))
                    .font(.system(.body, design: .default).weight(.semibold))
                    .foregroundStyle(Color.brandFgPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let reason = Formatters.matchReason(hit.source) {
                    Text(reason)
                        .font(.system(.caption2, design: .default))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.brandMintDim)
                        .accessibilityLabel(reason)
                }
                if !Formatters.scoreString(hit.score).isEmpty {
                    Text(Formatters.scoreString(hit.score))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.brandFgMuted)
                }
            }
            Text(Formatters.snippet(Formatters.stripContextHeader(hit.ocrTextSnippet)))
                .font(.system(.body, design: .default))
                .foregroundStyle(Color.brandFgSecondary)
                .lineLimit(3)
            // Entity chips + related-events badge. Only render the row
            // when there's something to show, so the backward-compat
            // zero-entity case stays visually identical to the pre-PR-2
            // layout.
            if !hit.entities.isEmpty || !hit.linkedEventIds.isEmpty {
                HStack(spacing: 6) {
                    EntityChipStrip(entities: hit.entities)
                    if let badge = Formatters.linkedBadge(hit.linkedEventIds) {
                        LinkedEventsBadge(label: badge)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
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
                    .accessibilityLabel("\(disp.overflow) more entities")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            entities.isEmpty ? "" : "Entities: \(entities.joined(separator: ", "))"
        )
    }
}

/// Single pill-shaped chip. Uniform mint styling; a subtly dimmer palette
/// distinguishes the overflow chip from real entity names.
struct EntityChip: View {
    let label: String
    var isOverflow: Bool = false

    var body: some View {
        Text(label)
            .font(.system(.caption2, design: .default))
            .foregroundStyle(
                isOverflow ? Color.brandFgMuted : Color.brandMint
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.brandMintSubtle.opacity(isOverflow ? 0.4 : 1.0))
            )
            .overlay(
                Capsule()
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
            Capsule()
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

#if DEBUG
    private func previewHit(
        id: UInt64,
        title: String,
        source: String = "hybrid",
        entities: [String] = [],
        linked: [UInt64] = []
    ) -> Hit {
        Hit(
            eventId: id, tsUs: 1_736_000_000_000_000,
            appBundleId: "com.apple.Safari", windowTitle: title,
            url: "https://example.org/",
            ocrTextSnippet: "Vector databases at scale: a survey of ANN methods.",
            source: source, score: 0.74,
            entities: entities, linkedEventIds: linked
        )
    }

    #Preview("HitRow cases") {
        VStack(alignment: .leading, spacing: 12) {
            HitRow(hit: previewHit(id: 1, title: "Apple — Privacy", source: "lexical"))
            HitRow(hit: previewHit(
                id: 2, title: "arxiv.org/abs/2312",
                entities: ["vector-db", "Anthropic", "embedding"]))
            HitRow(hit: previewHit(
                id: 3, title: "retriever.rs — mci",
                entities: ["sqlite-vec", "retriever", "MCI"],
                linked: [101, 102]))
            HitRow(hit: previewHit(
                id: 4, title: "#eng-brain — Slack",
                entities: ["MCI", "Anthropic", "sqlite-vec", "embedding",
                    "retriever", "vector-db", "MCP"],
                linked: [201, 202, 203, 204, 205]))
        }
        .padding()
        .background(Color.brandBgPrimary)
    }
#endif
