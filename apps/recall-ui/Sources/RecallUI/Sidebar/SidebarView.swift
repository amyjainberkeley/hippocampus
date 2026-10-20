import AppKit
import RecallUIKit
import SwiftUI

/// What the sidebar asks of the window.
struct SidebarActions {
    var openStatusMenu: (MenuAnchor.Holder) -> Void = { _ in }
    var openPreferences: () -> Void = {}
    var toggleSidebar: () -> Void = {}
    var hideItem: (String) -> Void = { _ in }
    var showInHistory: (String) -> Void = { _ in }
    var copyForYourAI: (String) -> Void = { _ in }
    var folderContext: () -> Void = {}
    var hideKind: (SidebarPlace) -> Void = { _ in }
    var toggleKind: (SidebarPlace) -> Void = { _ in }
    var resetSidebar: () -> Void = {}
    var setWorkingOnHidden: (Bool) -> Void = { _ in }
    var setLibraryCollapsed: (Bool) -> Void = { _ in }
    /// The pointer came into or left the sidebar: changes wait while it's in.
    var pointerInside: (Bool) -> Void = { _ in }
    /// A row's keyboard focus came into or left the sidebar.
    var focusInside: (Bool) -> Void = { _ in }
    /// The pointer rests on a Working On item (or left it): its frame in the
    /// window, for the preview.
    var hoverItem: (SidebarWorkItem?, CGRect) -> Void = { _, _ in }
}

/// The window's left navigation (SPEC 2.1 to 2.6 with SPEC-DELTA 1 and 2):
/// the hi mark, a scrolling middle (Today, Working On, Library) and a pinned
/// bottom (About You, AI Tools, Privacy, then the status and the gear) that
/// never scrolls away.
struct SidebarView: View {
    let model: SidebarModel
    /// The row for the page on screen; nil for a page without one.
    let selection: SidebarRow?
    let status: WindowStatus
    let choices: SidebarHides.Choices
    /// Working On's one-time footnote is showing.
    var showsFootnote = false
    /// Off-screen pictures draw the window's controls themselves; the live
    /// window's are the system's own.
    var drawsWindowControls = false
    var pictures: SidebarPictures
    var calendar: Calendar = .current
    var now: @Sendable () -> Date = { Date() }
    let select: (SidebarRow) -> Void
    var actions = SidebarActions()
    /// A picture of the pointer resting on this item.
    var restingOn: String?

    @State private var hiMarkAnchor = MenuAnchor.Holder()
    @State private var footerAnchor = MenuAnchor.Holder()
    @State private var hiMarkHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBand
            hiMark
            scrollingMiddle
            pinnedBottom
            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onHover { actions.pointerInside($0) }
    }

    // MARK: The top: the window's controls and the hi mark

    private var topBand: some View {
        HStack(spacing: 0) {
            if drawsWindowControls {
                WindowTrafficLights()
            }
            Spacer(minLength: 0)
            SidebarToggleButton(action: actions.toggleSidebar)
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .frame(height: 52)
        .background(WindowDragArea())
    }

    /// The hi mark is a button that opens the status menu (SPEC 2.6.1).
    private var hiMark: some View {
        Button {
            actions.openStatusMenu(hiMarkAnchor)
        } label: {
            WindowHiMarkView(remembering: status.remembering)
                .frame(height: 22)
                .foregroundStyle(MCI.Color.foreground)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: MCI.Radius.s, style: .continuous)
                        .fill(hiMarkHovered ? MCI.Color.hover : Color.clear)
                )
                .contentShape(Rectangle())
                .animation(MCI.Motion.snap, value: hiMarkHovered)
                .animation(MCI.Motion.snap, value: status.remembering)
        }
        .buttonStyle(.plain)
        .background(MenuAnchor(holder: hiMarkAnchor))
        .onHover { hiMarkHovered = $0 }
        .padding(.leading, 14)
        .padding(.bottom, MCI.Spacing.s)
        .accessibilityLabel(NavigationCopy.hiMarkLabel(status.title))
        .accessibilityHint(NavigationCopy.hiMarkHint)
    }

    // MARK: The scrolling middle

    private var selectionBinding: Binding<SidebarRow?> {
        Binding(get: { selection }, set: { row in if let row { select(row) } })
    }

    private var scrollingMiddle: some View {
        List(selection: selectionBinding) {
            ForEach(model.groups.filter { $0.section != .pinned }, id: \.section) { group in
                switch group.section {
                case .top:
                    ForEach(group.rows) { row in rowView(row).tag(row) }
                case .workingOn:
                    Section {
                        if !choices.workingOnHidden {
                            ForEach(group.rows) { row in rowView(row).tag(row) }
                        }
                        if showsFootnote, !choices.workingOnHidden {
                            Text(NavigationCopy.workingOnFootnote)
                                .font(.system(size: 11))
                                .foregroundStyle(MCI.Color.sidebarSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 25)
                                .selectionDisabled()
                                .transition(.opacity)
                        }
                    } header: {
                        SectionHeader(title: NavigationCopy.workingOn, collapsed: choices.workingOnHidden) {
                            actions.setWorkingOnHidden(!choices.workingOnHidden)
                        }
                        .contextMenu { sidebarMenu }
                    }
                case .library:
                    Section {
                        if !choices.libraryCollapsed {
                            ForEach(group.rows) { row in rowView(row).tag(row) }
                        }
                    } header: {
                        SectionHeader(title: NavigationCopy.library, collapsed: choices.libraryCollapsed) {
                            actions.setLibraryCollapsed(!choices.libraryCollapsed)
                        }
                        .contextMenu { sidebarMenu }
                    }
                case .pinned:
                    EmptyView()
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .animation(MCI.Motion.standard, value: model)
    }

    // MARK: The pinned bottom

    private var pinnedRows: [SidebarRow] {
        model.groups.first { $0.section == .pinned }?.rows ?? []
    }

    private var pinnedBottom: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(MCI.Color.sidebarLine)
                .frame(height: 1)
            List(selection: selectionBinding) {
                ForEach(pinnedRows) { row in rowView(row).tag(row) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: SidebarMetrics.rowHeight * CGFloat(pinnedRows.count) + 14)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                actions.openStatusMenu(footerAnchor)
            } label: {
                HStack(spacing: MCI.Spacing.s) {
                    StatusDot(dot: status.dot)
                    Text(verbatim: status.title)
                        .font(.system(size: 12))
                        .foregroundStyle(MCI.Color.sidebarSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, MCI.Spacing.s)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarHoverButtonStyle())
            .background(MenuAnchor(holder: footerAnchor))
            .accessibilityLabel(NavigationCopy.footerAccessibility(title: status.title, detail: status.detail))
            .accessibilityAddTraits(.isButton)
            Spacer(minLength: 0)
            Button(action: actions.openPreferences) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SidebarHoverButtonStyle())
            .help(NavigationCopy.preferencesMenu)
            .accessibilityLabel(NavigationCopy.preferences)
        }
        .padding(.top, MCI.Spacing.s)
        .padding(.bottom, MCI.Spacing.m)
        .padding(.leading, 12)
        .padding(.trailing, 10)
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: SidebarRow) -> some View {
        switch row {
        case let .place(place):
            PlaceRow(place: place, selected: selection == row, badged: model.badges.contains(place))
                .contextMenu {
                    if place.isLibraryKind {
                        Button(NavigationCopy.hideFromSidebar) { actions.hideKind(place) }
                    }
                }
        case let .workItem(id):
            if let item = model.items[id] {
                WorkingOnRow(item: item, selected: selection == row, pictures: pictures, calendar: calendar,
                             now: now, restingOn: restingOn == id, hover: actions.hoverItem)
                    .contextMenu {
                        Button(NavigationCopy.hideFromSidebar) { actions.hideItem(id) }
                        Button(UserFacingCopy.showInHistory) { actions.showInHistory(id) }
                        if item.kind == .code {
                            Button(NavigationCopy.contextForThisFolder) { actions.folderContext() }
                        }
                        Button(NavigationCopy.copyForYourAI) { actions.copyForYourAI(id) }
                    }
            }
        case .showAll:
            Text(NavigationCopy.showAll)
                .foregroundStyle(selection == row ? MCI.Color.foreground : MCI.Color.sidebarSecondary)
                .padding(.leading, SidebarMetrics.labelInset)
                .accessibilityLabel(NavigationCopy.showAllAccessibility(count: model.allItemCount))
        }
    }

    /// The View menu's Sidebar items, also on the section headers.
    @ViewBuilder
    private var sidebarMenu: some View {
        ForEach(SidebarPlace.libraryKinds) { kind in
            Toggle(kind.title, isOn: Binding(get: { model.kindsWithMoments.contains(kind) },
                                             set: { _ in actions.toggleKind(kind) }))
        }
        Divider()
        Button(NavigationCopy.resetSidebar, action: actions.resetSidebar)
    }
}

/// A section's header: the system's 11 pt semibold, in the secondary
/// label colour (SPEC 2.4). It collapses the section; its chevron shows
/// while the pointer is over it, and stays while the section is collapsed.
private struct SectionHeader: View {
    let title: String
    let collapsed: Bool
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MCI.Color.sidebarSecondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MCI.Color.sidebarSecondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .opacity(collapsed || hovered ? 1 : 0)
                    .padding(.trailing, 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(MCI.Motion.snap, value: hovered)
        .animation(MCI.Motion.snap, value: collapsed)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(collapsed ? "collapsed" : "")
    }
}

/// Sizes the sidebar shares.
enum SidebarMetrics {
    /// A row's height at the system's medium sidebar size.
    static let rowHeight: CGFloat = 28
    /// From a row's leading edge to its label: the icon's slot and the gap.
    static let labelInset: CGFloat = 25
    static let defaultWidth: CGFloat = 200
    static let minWidth: CGFloat = 180
    static let maxWidth: CGFloat = 260
}

/// A fixed place's row: its symbol, its name, the one badge.
private struct PlaceRow: View {
    let place: SidebarPlace
    let selected: Bool
    let badged: Bool

    var body: some View {
        HStack(spacing: 0) {
            Label {
                Text(place.title)
            } icon: {
                SidebarSymbol(name: place.systemImage, selected: selected)
            }
            Spacer(minLength: 0)
            if badged {
                Circle()
                    .fill(MCI.Color.accentFill)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .help(NavigationCopy.rowTooltip(place.title, key: place.key))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(place.key.map { "Command \($0)" } ?? "")
    }

    private var accessibilityLabel: String {
        guard badged else { return place.title }
        let badge = place == .aiTools ? NavigationCopy.aiToolsNeedsStep : NavigationCopy.aboutYouSomethingNew
        return "\(place.title), \(badge)"
    }
}

/// A row's symbol: secondary, the accent while selected, white on the
/// focused list's accent selection (SPEC 2.2).
struct SidebarSymbol: View {
    let name: String
    let selected: Bool
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: name)
            .foregroundStyle(style)
    }

    private var style: AnyShapeStyle {
        if prominence == .increased { return AnyShapeStyle(Color.white) }
        return selected ? AnyShapeStyle(MCI.Color.accent) : AnyShapeStyle(MCI.Color.foregroundSecondary)
    }
}

/// A Working On item: a little screenshot of its newest kept moment in the
/// symbol's place, or the kind's symbol when there is none (SPEC-DELTA 2).
private struct WorkingOnRow: View {
    let item: SidebarWorkItem
    let selected: Bool
    let pictures: SidebarPictures
    let calendar: Calendar
    let now: @Sendable () -> Date
    var restingOn = false
    let hover: (SidebarWorkItem?, CGRect) -> Void

    @State private var frame: CGRect = .zero
    @Environment(\.locale) private var locale

    var body: some View {
        Label {
            Text(verbatim: item.name)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            if item.thumbnailMoment != nil {
                SidebarThumbnail(moment: item.thumbnailMoment, pictures: pictures)
                    .frame(width: 18, height: 15, alignment: .trailing)
            } else {
                SidebarSymbol(name: item.systemImage, selected: selected)
            }
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear {
                    frame = proxy.frame(in: .global)
                    if restingOn { hover(item, frame) }
                }
                .onChange(of: proxy.frame(in: .global)) { _, new in
                    frame = new
                    if restingOn { hover(item, new) }
                }
        })
        .onHover { inside in hover(inside ? item : nil, frame) }
        .help(NavigationCopy.itemTooltip(name: item.name, when: when))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NavigationCopy.itemAccessibility(name: item.name, kind: item.kind.rawValue, when: when))
    }

    private var when: String {
        WorkingOnWhen.text(us: item.lastUs, now: now(), calendar: calendar, locale: locale)
    }
}

/// "today at 2:20 PM", "yesterday at 6:12 PM", "Oct 9 at 11:02 AM", on the
/// Mac's clock (RULINGS I4).
enum WorkingOnWhen {
    static func text(us: UInt64, now: Date, calendar: Calendar, locale: Locale) -> String {
        let date = Date(timeIntervalSince1970: Double(us) / 1_000_000)
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = locale
        time.setLocalizedDateFormatFromTemplate("jmm")
        let clock = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(clock)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(clock)"
        }
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = time.locale
        day.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(day.string(from: date)) at \(clock)"
    }
}

/// Where the sidebar's little screenshots come from: a moment's kept
/// screenshot, opened through the same encrypted path as every other.
struct SidebarPictures: Sendable {
    /// The file of `moment`'s kept screenshot, if it has one.
    var url: @Sendable (UInt64) async -> URL?
    /// Nil opens it with the window's own provider (`\.screenshots`).
    var provider: (any ThumbnailDataProviding)?

    static func reading(_ reader: BrainReader) -> SidebarPictures {
        SidebarPictures(url: { moment in
            (try? await reader.fetchEventsByIds([moment]))?.first?.thumbnailURL
        }, provider: nil)
    }
}

/// A moment's kept screenshot, small: 24 × 15 pt, 3 pt corners, a hairline
/// edge. Drawn through the same encrypted path as every screenshot.
struct SidebarThumbnail: View {
    let moment: UInt64?
    let pictures: SidebarPictures
    var size = CGSize(width: 24, height: 15)
    var cornerRadius: CGFloat = 3
    var maxPixelSize = 96

    @Environment(\.screenshots) private var screenshots
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(MCI.Color.surface)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipped()
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(MCI.Color.borderStrong.opacity(0.6), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
        .task(id: moment) { await load() }
    }

    private func load() async {
        guard let moment, let url = await pictures.url(moment) else { return }
        let key = "\(url.standardizedFileURL.path)#\(maxPixelSize)"
        if let kept = ScreenshotImageMemo.shared.image(for: key) {
            image = kept
            return
        }
        let picture = await MomentPicture.load(url: url, maxPixelSize: maxPixelSize, fullResolution: false,
                                               provider: pictures.provider ?? screenshots)
        guard !Task.isCancelled, case let .screenshot(data) = picture, let opened = NSImage(data: data) else { return }
        ScreenshotImageMemo.shared.keep(opened, cost: data.count, for: key)
        image = opened
    }
}

/// The larger preview of a Working On item while the pointer rests on it:
/// its screenshot, its name and when it was last worked on (SPEC-DELTA 2).
struct WorkingOnPreviewCard: View {
    let item: SidebarWorkItem
    let pictures: SidebarPictures
    var calendar: Calendar = .current
    var now: @Sendable () -> Date = { Date() }

    static let size = CGSize(width: 236, height: 196)

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if item.thumbnailMoment != nil {
                SidebarThumbnail(moment: item.thumbnailMoment, pictures: pictures,
                                 size: CGSize(width: 220, height: 138), cornerRadius: 6, maxPixelSize: 520)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MCI.Color.foreground)
                    .lineLimit(1)
                Text(verbatim: NavigationCopy.lastWorkedOn(
                    WorkingOnWhen.text(us: item.lastUs, now: now(), calendar: calendar, locale: locale)))
                    .font(.system(size: 12))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .padding(8)
        .frame(width: Self.size.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MCI.Color.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(MCI.Color.border, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 6)
        .accessibilityHidden(true)
    }
}

/// The footer's dot: blue while remembering, a hollow grey ring when not,
/// red for a failure (SPEC 2.6.3). It never pulses.
struct StatusDot: View {
    let dot: WindowStatus.Dot

    var body: some View {
        ZStack {
            switch dot {
            case .on:
                Circle().fill(MCI.Color.accentFill)
            case .off:
                Circle().strokeBorder(MCI.Color.foregroundMuted, lineWidth: 1.5)
            case .problem:
                Circle().fill(MCI.Color.error)
            }
        }
        .frame(width: 7, height: 7)
        .animation(MCI.Motion.snap, value: dot)
        .accessibilityHidden(true)
    }
}

/// The system's sidebar button: shows or hides the sidebar (⌃⌘S).
struct SidebarToggleButton: View {
    let action: () -> Void
    var hidesSidebar = true

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15))
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarHoverButtonStyle())
        .help(hidesSidebar ? NavigationCopy.hideSidebar : NavigationCopy.showSidebar)
        .accessibilityLabel(hidesSidebar ? NavigationCopy.hideSidebar : NavigationCopy.showSidebar)
    }
}

/// A borderless button that shows a soft fill while the pointer is over it.
struct SidebarHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: MCI.Radius.s, style: .continuous)
                        .fill(hovered || configuration.isPressed ? MCI.Color.hover : Color.clear)
                )
                .onHover { hovered = $0 }
                .animation(MCI.Motion.snap, value: hovered)
        }
    }
}

/// The window's close, minimize and zoom buttons, drawn only in off-screen
/// pictures where the system draws none; the live window has its own in the
/// same place.
struct WindowTrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { color in
                Circle()
                    .fill(Color(.sRGB, red: Double((color >> 16) & 0xFF) / 255,
                                green: Double((color >> 8) & 0xFF) / 255, blue: Double(color & 0xFF) / 255))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
                    .frame(width: 12, height: 12)
            }
        }
        .accessibilityHidden(true)
    }
}

/// An empty stretch of the window's top that moves the window when dragged
/// and zooms it on a double click, as a title bar does.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                switch action {
                case "Minimize": window?.performMiniaturize(nil)
                case "None": break
                default: window?.performZoom(nil)
                }
                return
            }
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Where a menu opens from: the view a button sits on.
struct MenuAnchor: NSViewRepresentable {
    final class Holder {
        weak var view: NSView?
    }

    let holder: Holder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }
}
