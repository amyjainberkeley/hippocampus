import AppKit
import RecallUIKit
import SwiftUI

/// One Working On item in the sidebar (SPEC 2.2, SPEC-DELTA 2): a small
/// thumbnail of its newest kept screenshot in place of its kind's symbol
/// (about 26 × 16 pt, 3 pt corners, a hairline), or the symbol when it has
/// none; its name, cut with "…", the whole name and when it was last worked
/// on in its tooltip. Hovering shows a larger preview (220 × 138 pt) with
/// its name and "Last worked on …", fading in after 0.4 s as the day
/// strip's does. The shell's sidebar draws it in its list.
struct WorkingOnSidebarRow: View {
    let item: WorkItem
    /// Its thumbnail moment, read (`WorkMomentCache`).
    let picture: Hit?
    let now: Date
    let calendar: Calendar
    /// Renders draw the preview beside the row, as it shows on screen.
    var previewInline = false

    static let thumbnailSize = CGSize(width: 26, height: 16)
    static let previewSize = CGSize(width: 220, height: 138)
    /// How long the pointer rests before the preview shows.
    static let previewDelay: Duration = .milliseconds(400)

    @State private var showsPreview = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        Label {
            Text(verbatim: item.name)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            thumbnail
        }
        .help(WorkFormat.tooltip(item, now: now, calendar: calendar))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WorkFormat.accessibilityLabel(item, now: now, calendar: calendar))
        .accessibilityAddTraits(.isButton)
        .onHover { inside in
            pending?.cancel()
            if inside {
                pending = Task { @MainActor in
                    try? await Task.sleep(for: Self.previewDelay)
                    guard !Task.isCancelled else { return }
                    showsPreview = true
                }
            } else {
                showsPreview = false
            }
        }
        .onDisappear {
            pending?.cancel()
            showsPreview = false
        }
        .background(
            FloatingPreview(isShown: showsPreview && !previewInline) {
                WorkHoverPreview(item: item, picture: picture, now: now, calendar: calendar)
            }
        )
        .overlay(alignment: .topLeading) {
            if previewInline {
                WorkHoverPreview(item: item, picture: picture, now: now, calendar: calendar, animates: false)
                    .fixedSize()
                    .offset(x: 192, y: -60)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if picture?.thumbnailURL != nil {
            MomentPictureView(hit: picture, size: Self.thumbnailSize, cornerRadius: 3)
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
        } else {
            Image(systemName: WorkFormat.symbol(item.kind))
                .foregroundStyle(MCI.Color.foregroundSecondary)
        }
    }
}

/// The larger preview of a Working On item: its screenshot, its name and
/// when it was last worked on, on the day strip's card.
struct WorkHoverPreview: View {
    let item: WorkItem
    let picture: Hit?
    let now: Date
    let calendar: Calendar
    var animates = true

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MomentPictureView(hit: picture, size: WorkingOnSidebarRow.previewSize,
                              appBundleId: item.apps.first)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(MCI.Color.border, lineWidth: 1))
            Text(verbatim: item.name)
                .font(MCI.Font.bodyStrong)
                .foregroundStyle(MCI.Color.foreground)
                .lineLimit(1)
            Text(verbatim: WorkCopy.lastWorkedOn(WorkFormat.when(us: item.lastUs, now: now, calendar: calendar)))
                .font(MCI.Font.caption)
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(width: WorkingOnSidebarRow.previewSize.width + 16, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MCI.Color.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(MCI.Color.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .opacity(animates && !appeared ? 0 : 1)
        .scaleEffect(animates && !appeared && !reduceMotion ? 0.96 : 1)
        .onAppear {
            guard animates else { return }
            withAnimation(MCI.Motion.snap) { appeared = true }
        }
        .accessibilityHidden(true)
    }
}

/// A preview that floats beside its view, outside the sidebar's bounds: a
/// borderless, transparent child panel of the window that never takes
/// focus or clicks, shown and hidden with `isShown`.
struct FloatingPreview<Content: View>: NSViewRepresentable {
    let isShown: Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        if isShown {
            context.coordinator.show(content(), beside: view)
        } else {
            context.coordinator.hide()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.hide()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var panel: NSPanel?

        func show(_ content: some View, beside anchor: NSView) {
            // Shown already: the same card stays where it is.
            guard panel == nil, let window = anchor.window else { return }
            // Room around the card for its shadow.
            let margin: CGFloat = 16
            let hosting = NSHostingView(rootView: content.padding(margin))
            hosting.appearance = window.effectiveAppearance
            let size = hosting.fittingSize
            let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let screen = window.screen?.visibleFrame ?? .infinite
            var origin = NSPoint(x: anchorFrame.maxX + 8 - margin, y: anchorFrame.midY - size.height / 2)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
            let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.contentView = hosting
            window.addChildWindow(panel, ordered: .above)
            self.panel = panel
        }

        func hide() {
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
        }
    }
}
