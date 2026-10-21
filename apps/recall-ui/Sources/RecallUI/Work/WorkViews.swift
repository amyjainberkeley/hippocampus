import AppKit
import RecallUIKit
import SwiftUI

// The pieces Working On, its item pages, Web Pages, Looked Up and Resume
// share, drawn as the approved prototype draws them: a 22 pt title, 17 pt
// section titles, cards on the surface with a hairline and 12 pt corners,
// and History's own rows.

/// The kind's symbol on a quiet tile: an item page's header (40 pt) and
/// Show All's cards.
struct WorkKindTile: View {
    let kind: WorkItem.Kind
    var side: CGFloat = 40

    var body: some View {
        Image(systemName: WorkFormat.symbol(kind))
            .font(.system(size: side * 0.48, weight: .regular))
            .foregroundStyle(MCI.Color.foregroundSecondary)
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: side / 4, style: .continuous).fill(MCI.Color.surface))
            .overlay(RoundedRectangle(cornerRadius: side / 4, style: .continuous)
                .strokeBorder(MCI.Color.border, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// A card on the page: the surface, a hairline and 12 pt corners.
struct WorkCard: ViewModifier {
    var padding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: MCI.Radius.l, style: .continuous).fill(MCI.Color.surface))
            .overlay(RoundedRectangle(cornerRadius: MCI.Radius.l, style: .continuous)
                .strokeBorder(MCI.Color.border, lineWidth: 1))
    }
}

extension View {
    func workCard(padding: CGFloat = 20) -> some View {
        modifier(WorkCard(padding: padding))
    }
}

/// A section's title and, under it, its one quiet line.
struct WorkSectionTitle: View {
    let title: String
    var lead: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .mciFont(.title2)
                .foregroundStyle(MCI.Color.foreground)
                .accessibilityAddTraits(.isHeader)
            if let lead {
                Text(lead)
                    .font(.system(size: 12))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
            }
        }
    }
}

/// A small bordered button, as the prototype's secondary actions.
struct WorkButtonStyle: ButtonStyle {
    var prominent = false
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 12 : 13, weight: prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Color.white : MCI.Color.foreground)
            .padding(.horizontal, small ? 9 : 11)
            .frame(height: small ? 22 : 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(prominent ? MCI.Color.accentFill : MCI.Color.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(prominent ? Color.black.opacity(0.12) : Color.primary.opacity(0.16), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.07), radius: 0.75, y: 0.5)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// A link-blue text button with a chevron: "See What It Gets ›".
struct WorkLinkButton: View {
    let title: String
    var chevron = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(MCI.Color.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A moment's picture at any size: its kept screenshot through the window's
/// provider, or its app's tile when it has none.
struct MomentPictureView: View {
    let hit: Hit?
    let size: CGSize
    var appBundleId: String?
    var cornerRadius: CGFloat = 6

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        EvidenceThumbnail(url: hit?.thumbnailURL, appBundleId: hit?.appBundleId ?? appBundleId, size: size,
                          maxPixelSize: MomentPicture.pixels(for: size, scale: displayScale),
                          contentMode: .fill, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A row in History's look for a lens (Web Pages, Looked Up): its picture,
/// a headline, one or two lines of text, the line under it and its time,
/// with the lens's own headline and line.
struct LensRow: View {
    let hit: Hit?
    let headline: String
    /// "Chrome · devnotes.example".
    let place: String
    /// " · on 3 days", "· searched 3 times": quieter, after the place.
    var extra: String?
    let when: String
    /// A picture of its own in place of the moment's: a search engine's
    /// letter.
    var picture: AnyView?
    var appBundleId: String?

    var body: some View {
        HStack(alignment: .top, spacing: MCI.Spacing.m - 2) {
            if let picture {
                picture.frame(width: HitRow.pictureSize.width, height: HitRow.pictureSize.height)
            } else {
                EvidenceThumbnail(url: hit?.thumbnailURL, appBundleId: hit?.appBundleId ?? appBundleId,
                                  size: HitRow.pictureSize, maxPixelSize: 240, contentMode: .fill, alignment: .top)
            }
            VStack(alignment: .leading, spacing: MCI.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: MCI.Spacing.s) {
                    Text(verbatim: headline)
                        .mciFont(.bodyStrong)
                        .foregroundStyle(Color.brandFgPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(verbatim: when)
                        .mciFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.brandFgSecondary)
                }
                Text(verbatim: hit.map(MomentRowText.preview) ?? " ")
                    .mciFont(.body)
                    .foregroundStyle(Color.brandFgSecondary)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                (Text(verbatim: place).foregroundStyle(Color.brandFgSecondary)
                    + Text(verbatim: extra.map { " \u{00B7} \($0)" } ?? "").foregroundStyle(Color.brandFgMuted))
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, MCI.Spacing.s - 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A search engine's letter on a soft tile, where a search's row has no
/// screenshot: "G".
struct EngineTile: View {
    let engine: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MCI.Radius.xs, style: .continuous)
                .fill(MCI.Color.surface)
                .overlay(RoundedRectangle(cornerRadius: MCI.Radius.xs, style: .continuous)
                    .strokeBorder(MCI.Color.border, lineWidth: 0.5))
            Text(verbatim: String(engine.prefix(1)))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(MCI.Color.accentDim)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MCI.Color.accentSubtle))
        }
        .accessibilityHidden(true)
    }
}

/// A quiet row of a list on an item page: its title and its line, a
/// hairline under it.
struct NearRowView: View {
    let title: String
    let detail: String
    var monospaced = false
    var symbol: String?
    var trailing: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: symbol == nil ? .top : .center, spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(MCI.Color.foregroundMuted)
                        .frame(width: 15)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
                        .foregroundStyle(MCI.Color.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(MCI.Color.foregroundSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(verbatim: trailing)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                }
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(MCI.Color.border).frame(height: 1)
            }
            .background(hovering ? Color.primary.opacity(0.03) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The page-wide empty, failed and loading states of a Working On place,
/// in the window's canonical shape.
struct WorkEmptyState: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(MCI.Color.foregroundMuted)
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MCI.Color.foreground)
            if let message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(WorkButtonStyle())
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 80)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }
}

/// Moments read by id for pictures (the sidebar's thumbnails, Show All's
/// cards): in memory only, and gone after any delete.
@MainActor
final class WorkMomentCache: ObservableObject {
    static let shared = WorkMomentCache()

    @Published private(set) var hits: [UInt64: Hit] = [:]
    private var generation: UInt64 = MemoryDeletionSignal.shared.generation
    private var asked: Set<UInt64> = []

    func hit(_ id: UInt64?) -> Hit? {
        guard let id else { return nil }
        dropIfDeleted()
        return hits[id]
    }

    /// Read the moments not read yet.
    func load(_ ids: [UInt64], reader: any BrainReader) async {
        dropIfDeleted()
        let wanted = ids.filter { hits[$0] == nil && !asked.contains($0) }
        guard !wanted.isEmpty else { return }
        asked.formUnion(wanted)
        let found = (try? await WorkingOnItemModel.fetch(wanted, reader: reader)) ?? []
        for hit in found { hits[hit.id] = hit }
        // A read that found nothing is asked again next time.
        asked.subtract(wanted.filter { hits[$0] == nil })
    }

    private func dropIfDeleted() {
        let current = MemoryDeletionSignal.shared.generation
        guard current != generation else { return }
        hits.removeAll()
        asked.removeAll()
        generation = current
    }
}

extension WorkItemMenuItem {
    /// The item's words in its menus.
    var title: String {
        switch self {
        case .showInSidebar: WorkCopy.showInSidebar
        case .hideFromSidebar: WorkCopy.hideFromSidebar
        case .showInHistory: WorkCopy.showInHistory
        case .contextForThisFolder: NavigationCopy.contextForThisFolder
        case .copyForYourAI: HandoffCopy.copyForYourAI
        }
    }
}
