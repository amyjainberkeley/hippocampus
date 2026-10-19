import AppKit
import RecallUIKit
import SwiftUI

/// In place of a screenshot: the moment's app, calmly. A moment saved as text
/// only, a screenshot still opening and one that cannot be opened all show
/// this, never a broken-image square. Wide and short, the icon sits beside
/// its caption; otherwise above it.
struct MomentTile: View {
    let appBundleId: String?
    /// A short line under (or beside) the icon: "Text only", or why the
    /// screenshot is not shown. Lists show none.
    var caption: String? = nil
    /// While a screenshot opens the tile is quieter still.
    var isQuiet = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let wide = caption != nil && size.width > size.height * 3
            ZStack {
                RoundedRectangle(cornerRadius: MCI.Radius.xs, style: .continuous)
                    .fill(Color.brandCardBg)
                if wide {
                    HStack(spacing: MCI.Spacing.m) {
                        icon(side: min(size.height * 0.56, 40))
                        captionText
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, MCI.Spacing.l)
                } else {
                    VStack(spacing: MCI.Spacing.s) {
                        icon(side: iconSide(for: size))
                        captionText
                    }
                    .padding(MCI.Spacing.xs)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private func icon(side: CGFloat) -> some View {
        AppIcon(bundleId: appBundleId ?? "")
            .frame(width: side, height: side)
            .opacity(isQuiet ? 0.55 : 1)
    }

    @ViewBuilder
    private var captionText: some View {
        if let caption {
            Text(caption)
                .font(MCI.Font.caption)
                .foregroundStyle(Color.brandFgMuted)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    private func iconSide(for size: CGSize) -> CGFloat {
        let share: CGFloat = caption == nil ? 0.62 : 0.34
        return max(14, min(min(size.width, size.height) * share, 56))
    }
}

/// App icons by bundle id, looked up once: a row drawn again never asks
/// Launch Services again. An app that is not on this Mac is remembered as
/// missing.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private var icons: [String: NSImage?] = [:]

    func icon(for bundleId: String) -> NSImage? {
        if let known = icons[bundleId] { return known }
        let found = bundleId.isEmpty ? nil : NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleId)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        if icons.count >= 256 { icons.removeAll() }
        icons[bundleId] = found
        return found
    }
}

/// An app that is not on this Mac: the first letter of its name on a soft
/// tile, instead of the system's blank app placeholder.
struct AppMonogram: View {
    let bundleId: String

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                    .fill(Color.brandMintSubtle)
                if let letter {
                    Text(verbatim: letter)
                        .font(.system(size: side * 0.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.brandMintDim)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: side * 0.46, weight: .regular))
                        .foregroundStyle(Color.brandMintDim)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    private var letter: String? {
        guard !bundleId.trimmingCharacters(in: .whitespaces).isEmpty,
              let first = Formatters.appDisplayName(bundleId).first(where: \.isLetter)
        else { return nil }
        return String(first).uppercased()
    }
}
