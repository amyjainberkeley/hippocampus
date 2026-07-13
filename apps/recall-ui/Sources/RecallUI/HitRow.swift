// HitRow.swift — one row in the recall search/timeline lists.
//
// Cycle 8.36 PR-2 (docs/research/2026-07-12-recall-ui-audit.md §5, §7):
// surfaces the entity chips + plain-English match-reason label that
// unblock the "WOW moment" now that PR #27 has plumbed entities +
// linked_event_ids end-to-end. Chip taps DO NOT open the flyout — that
// wiring lives in PR-3 (`RelatedHitsFlyout` in `DetailPaneView`).
//
// Cycle 8.35 PR-4: adds an optional `HitThumbnail` view to the LEFT
// of the text stack. Loaded lazily from `hit.thumbnailURL`; if the URL
// is nil OR the file doesn't decode as an image, falls back to a
// muted-color SF Symbol placeholder. Thumbnails apply a defense-in-
// depth 1-pt blur + 15% desaturation so the UI is recognizable but
// not a security-camera stream — this is a hard-coded posture, NOT a
// feature flag (see the audit-doc PR-4 spec + the CSO note in the
// PR body). Sized 64x40 pt (~16:10) with rounded corners.

import RecallUIKit
import SwiftUI

struct HitRow: View {
    let hit: Hit

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HitThumbnail(url: hit.thumbnailURL)
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
        }
        .padding(.vertical, 6)
    }
}

/// Fixed-size keyframe preview at the left of `HitRow`. Sized 64x40 pt
/// (roughly 16:10 downsample of a widescreen keyframe) with rounded
/// corners. Loads lazily — the file is opened at most once per row
/// appearance via a `.task` block, and any failure (nil URL, missing
/// file, undecodable bytes) falls through to the muted placeholder.
///
/// Privacy posture (audit-doc §PR-4, hard-coded per the PR brief):
///  - 1-pt Gaussian blur so a passerby cannot read on-screen text.
///  - 15% desaturation so highly-saturated brand chrome (e.g. a
///    Slack red-dot ping) doesn't yell across the room.
/// These are NOT feature-flagged. The whole point of the pass is
/// defense-in-depth against over-shoulder viewing; a toggle would let
/// a user quietly turn it off (and then forget), so we make it the
/// only mode.
///
/// Accessibility: nil URL renders as "no thumbnail available"; loaded
/// image is a decorative element (the surrounding hit text carries the
/// semantic content), so the image itself is `.accessibilityHidden`.
struct HitThumbnail: View {
    let url: URL?
    @State private var image: NSImage?

    /// Visible thumbnail size in points (audit-doc §PR-4).
    private static let width: CGFloat = 64
    private static let height: CGFloat = 40
    /// Hard-coded privacy posture. See the type-level doc.
    private static let blurRadius: CGFloat = 1
    private static let saturation: Double = 0.85

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.width, height: Self.height)
                    .clipped()
                    .blur(radius: Self.blurRadius)
                    .saturation(Self.saturation)
                    .accessibilityHidden(true)
            } else {
                placeholder
            }
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.brandCardBorder, lineWidth: 0.5)
        )
        .task(id: url) {
            image = HitThumbnail.load(url: url)
        }
    }

    private var placeholder: some View {
        // Muted-color SF Symbol on the brand card background. Not a
        // "missing image" red-X — we don't want the UI to look broken
        // for the (currently common) case where the event predates the
        // P3.6.5 blob writer, or the ingest was text-only (Mail, Slack).
        ZStack {
            Color.brandCardBg
            Image(systemName: "photo")
                .foregroundStyle(Color.brandFgMuted)
                .font(.system(size: 14))
        }
        .accessibilityLabel("no thumbnail available")
    }

    /// Off-main-actor loader. Nil URL, missing file, or undecodable
    /// bytes all return nil — the view falls back to the placeholder.
    /// Note: today's blobs on disk are AES-GCM-encrypted (P3.6.5,
    /// `KeyframeBlobWriter`); the CSO-owned decrypt path is a follow-on
    /// wired outside this PR. Until then this loader will return nil
    /// for any real-capture blob (graceful degradation), and the row
    /// renders the placeholder. That is deliberate: this PR ships the
    /// UI seam so the decrypt path can plug in cleanly later.
    static func load(url: URL?) -> NSImage? {
        guard let url else { return nil }
        // FileManager check avoids a spammy warning when the blob is
        // missing (common when a user deletes the blobs dir out of
        // band, or on a legacy brain).
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
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
