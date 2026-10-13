import AppKit
import ApplicationServices
import Combine
import HippocampusKit
import SwiftUI

// MARK: Controller

/// Owns Ask. The key (Shift twice unless the person chose another), ⌃⇧Space,
/// the menu and `hippocampus://ask` open it. It drops from the top bar of the
/// screen the pointer is on, over whatever app is in front, and never
/// activates Hippocampus, so the window being asked about stays in front and
/// stays the one being read.
@MainActor
final class CommandBarController: NSObject, NSWindowDelegate {
    static let shared = CommandBarController()

    private var panel: CommandBarPanel?
    private var model: CommandBarModel?
    private var supervisor: ProcessSupervisor?
    private var openEvent: ((UInt64) -> Void)?
    private var openWindow: ((String) -> Void)?
    private var statusAction: ((AskPanelStatus.Action) -> Void)?
    private var announceShown: (() -> Void)?
    /// Where the panel hangs this time; set on every show.
    private var placement: AskPanelPlacement?
    /// The content's own height, as the view last measured it.
    private var contentHeight = AskPanelPlacement.shortest
    /// While the entrance runs, a new height is only recorded.
    private var entering = false
    private var statusWatch: AnyCancellable?
    private var closeAfterCopy: Task<Void, Never>?
    /// ⇧⌘C's fetch, cancelled when Ask closes.
    private var copyForAITask: Task<Void, Never>?
    /// When a `hippocampus://ask` link last opened Ask (RULINGS S12).
    private var linkOpenedAt: Date?

    func configure(
        model: CommandBarModel,
        supervisor: ProcessSupervisor,
        openEvent: @escaping (UInt64) -> Void,
        openWindow: @escaping (String) -> Void,
        statusAction: @escaping (AskPanelStatus.Action) -> Void,
        announceShown: @escaping () -> Void
    ) {
        self.model = model
        self.supervisor = supervisor
        self.openEvent = openEvent
        self.openWindow = openWindow
        self.statusAction = statusAction
        self.announceShown = announceShown
    }

    /// The key again closes it; it does not jump screens. Only the key and
    /// Esc close Ask this way (RULINGS S12).
    func toggle() {
        if AskPanelDismissal.closes(.key, visible: panel?.isVisible == true) { hide() } else { show(from: .key) }
    }

    /// The menu and a link only ever show Ask, even when it is up already
    /// (RULINGS S12): a second link never hides an answer on its way.
    func show(asking question: String? = nil, from opening: AskPanelDismissal.Opening = .menu) {
        guard let model else { return }
        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        if opening == .link {
            linkOpenedAt = Date()
            // Opening the link may have activated Hippocampus: keep the
            // keyboard in Ask.
            if panel.isVisible { panel.makeKeyAndOrderFront(nil) }
        }
        if !panel.isVisible {
            // The status is polled every 5 s; read it now, as the menu does.
            if let supervisor {
                supervisor.refreshCaptureStatus()
                model.setStatus(supervisor.askPanelStatus())
            }
            let openID = model.opened()
            present(panel)
            watchStatus()
            SoloKeyMonitor.shared.recheck()
            announceShown?()
            fillContext(openID: openID)
        }
        // Sent once the window in front is known.
        if let question { model.ask(question) }
    }

    /// On quit: close Ask and stop its sessions, waiting until they have
    /// exited (spec-shell S6.2).
    func shutdown() async {
        hide()
        await model?.shutdown()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        model?.closed()
        statusWatch = nil
        closeAfterCopy?.cancel()
        closeAfterCopy = nil
        copyForAITask?.cancel()
        copyForAITask = nil
        // Opened from a link, the app was activated: give focus back to the
        // app the person was in, unless a Hippocampus window is in use.
        let others = NSApp.windows.filter { !($0 is CommandBarPanel) }.map {
            AskPanelDismissal.Window(isVisible: $0.isVisible, isTitled: $0.styleMask.contains(.titled))
        }
        if AskPanelDismissal.shouldHideApp(appIsActive: NSApp.isActive, otherWindows: others) {
            NSApp.hide(nil)
        }
    }

    private func makePanel(model: CommandBarModel) -> CommandBarPanel {
        let panel = CommandBarPanel()
        panel.onCancel = { [weak self, weak model] in
            if model?.back() != true { self?.hide() }
        }
        panel.onKeyCommand = { [weak self] command in self?.handle(command) ?? false }
        let view = CommandBarView(
            model: model,
            perform: { [weak self] action in self?.perform(action) },
            close: { [weak self] in self?.hide() },
            heightChanged: { [weak self] height in self?.resize(height: height) }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.delegate = self
        return panel
    }

    // MARK: Placement and entrance (spec-shell S1)

    private func present(_ panel: CommandBarPanel) {
        let screens = NSScreen.screens.map(Self.placementScreen)
        guard let screen = AskPanelPlacement.screen(
            containing: NSEvent.mouseLocation, in: screens, main: NSScreen.main.map(Self.placementScreen)
        ) else { return }
        let placement = AskPanelPlacement(screen: screen)
        self.placement = placement
        model?.maxContentHeight = placement.maxContentHeight
        let final = placement.frame(height: contentHeight)
        let entrance = AskPanelEntrance(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        panel.setFrame(entrance.start(for: final), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        entering = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = entrance.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.entranceEnded() }
        })
    }

    private func entranceEnded() {
        entering = false
        resize(height: contentHeight)
    }

    /// Hangs from the same top edge and grows downward only, never past the
    /// cap; past it the content scrolls.
    private func resize(height: CGFloat) {
        contentHeight = height
        guard !entering, let panel, panel.isVisible, let placement else { return }
        let frame = placement.frame(height: height)
        guard abs(panel.frame.height - frame.height) > 0.5 || abs(panel.frame.maxY - frame.maxY) > 0.5 else { return }
        panel.setFrame(frame, display: true, animate: false)
    }

    private static func placementScreen(_ screen: NSScreen) -> AskPanelPlacement.Screen {
        AskPanelPlacement.Screen(
            frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top
        )
    }

    // MARK: Status

    /// The footer and the mark follow the status while Ask is up. The
    /// supervisor announces a change before making it, so read it a turn
    /// later.
    private func watchStatus() {
        guard let supervisor else { return }
        statusWatch = supervisor.objectWillChange
            .receive(on: RunLoop.main)
            .map { [weak supervisor] _ in
                MainActor.assumeIsolated { supervisor?.askPanelStatus() }
            }
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] status in
                MainActor.assumeIsolated { self?.model?.setStatus(status) }
            }
    }

    // MARK: Actions

    private func handle(_ command: AskKeyCommand) -> Bool {
        if command == .close {
            hide()
            return true
        }
        guard let action = model?.action(for: command) else { return false }
        perform(action)
        return true
    }

    private func perform(_ action: BarAction) {
        switch action {
        case .openURL(let url):
            hide()
            NSWorkspace.shared.open(url)
        case .openEvent(let id):
            hide()
            openEvent?(id)
        case .openWindow(let tab):
            hide()
            openWindow?(tab)
        case .copy(let text):
            copy(text)
        case .copyForAI:
            // Tied to this open: closing Ask cancels it, and a result that
            // arrives after Ask closed or opened again is dropped.
            guard let model else { return }
            copyForAITask?.cancel()
            copyForAITask = Task { [weak self] in
                let result = await model.copyForAI()
                guard !Task.isCancelled else { return }
                switch result {
                case .text(let text): self?.copy(text)
                case .failed: model.showFlash("Couldn’t copy. Try again.")
                case .dropped: break
                }
            }
        case .status(let action):
            statusAction?(action)
        }
    }

    /// "Copied" in the footer for a moment, then Ask closes.
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model?.showFlash("Copied")
        closeAfterCopy?.cancel()
        closeAfterCopy = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Clicking away closes Ask. A link activates Hippocampus as it opens
    /// Ask, which can take the keyboard a moment later; that is not the
    /// person clicking away, so Ask takes the keyboard back instead.
    func windowDidResignKey(_ notification: Notification) {
        let sinceLink = linkOpenedAt.map { Date().timeIntervalSince($0) }
        guard AskPanelDismissal.closesOnResignKey(sinceLinkOpen: sinceLink) else {
            DispatchQueue.main.async { [weak self] in
                guard let panel = self?.panel, panel.isVisible, !panel.isKeyWindow else { return }
                panel.makeKeyAndOrderFront(nil)
            }
            return
        }
        hide()
    }

    // MARK: The window in front

    /// Read after Ask is up, so the panel never waits on Accessibility
    /// (RULINGS S9). Hippocampus's own windows are not context.
    private func fillContext(openID: Int) {
        guard let model else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else {
            model.contextArrived(nil, openID: openID)
            return
        }
        let pid = app.processIdentifier
        let bundleId = app.bundleIdentifier
        let name = app.localizedName
        Task.detached(priority: .userInitiated) {
            let title = Self.focusedWindowTitle(pid: pid)
            await model.contextArrived(
                FrontmostContext(bundleId: bundleId, appName: name, windowTitle: title), openID: openID
            )
        }
    }

    /// The focused window's title when Accessibility allows reading it.
    nonisolated private static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.15)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var value: CFTypeRef?
        // swiftlint:disable:next force_cast
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value) == .success
        else { return nil }
        return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A borderless, non-activating panel that takes keyboard focus without
/// taking it from the app you are in, like Spotlight. It hangs from the top
/// bar and cannot be dragged.
final class CommandBarPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: AskPanelPlacement.preferredWidth, height: AskPanelPlacement.shortest),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        isMovableByWindowBackground = false
        isMovable = false
        // The entrance is drawn by the controller.
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc anywhere in the panel, even when the field has lost focus.
    var onCancel: (() -> Void)?
    /// ⌘C, ⇧⌘C, ⌘D, ⌘U and ⌘Q, seen before the field or the main menu
    /// takes them. Returns false to let them through.
    var onKeyCommand: ((AskKeyCommand) -> Bool)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        if let key = event.charactersIgnoringModifiers,
           let command = AskKeyCommand(
               key: key,
               command: flags.contains(.command),
               shift: flags.contains(.shift),
               option: flags.contains(.option),
               control: flags.contains(.control)
           ),
           onKeyCommand?(command) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: Views

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A solid fill in place of the window-server material, which an off-screen
/// render draws blank. Only the preview renderer sets it.
private struct AskSolidBackgroundKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var askSolidBackground: Bool {
        get { self[AskSolidBackgroundKey.self] }
        set { self[AskSolidBackgroundKey.self] = newValue }
    }
}

struct CommandBarView: View {
    static let searchHeight: CGFloat = 60
    static let corner: CGFloat = 22

    @ObservedObject var model: CommandBarModel
    let perform: (BarAction) -> Void
    let close: () -> Void
    let heightChanged: (CGFloat) -> Void
    @FocusState private var focused: Bool
    /// The row under the pointer: highlighted, never chosen, so Return keeps
    /// asking (product critique 6).
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            if hasContent {
                Divider().opacity(0.6)
                content
                    .frame(maxHeight: model.maxContentHeight)
            }
            Divider().opacity(0.6)
            footer
        }
        .frame(maxWidth: .infinity)
        // Measure the content's ideal height, not the window's current one:
        // a scroll view takes whatever height it is given, so measuring the
        // laid-out height would keep the panel at its first size.
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in Color.clear.preference(key: HeightKey.self, value: proxy.size.height) })
        .modifier(GlassBackground(corner: Self.corner))
        .frame(maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(HeightKey.self) { height in heightChanged(height) }
        .onAppear { focused = true }
        .onChange(of: model.mode) { _, _ in focused = true }
        .onChange(of: model.focusRequest) { _, _ in
            // After the panel becomes key; a focus set before that is lost.
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: model.selectQuestionRequest) { _, _ in
            // A kept question comes back selected, so typing replaces it.
            DispatchQueue.main.async {
                focused = true
                DispatchQueue.main.async {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
        }
    }

    private var hasContent: Bool {
        !model.rows.isEmpty || model.mode == .answer || model.notice != nil
    }

    // Search row

    private var searchRow: some View {
        HStack(spacing: 12) {
            HiMarkView(style: .brand, state: model.status.mark)
                .frame(height: 17)
                .frame(width: 22, height: 22)
                .foregroundStyle(.primary)
            TextField(model.placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($focused)
                .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                .onKeyPress(.escape) {
                    if !model.back() { close() }
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { _ in
                    if let action = model.activate() { perform(action) }
                    return .handled
                }
            // The answer card shows its own progress.
            if model.isSearching {
                ProgressView().controlSize(.small)
            }
            if let context = model.context, let name = context.appName {
                ContextChip(
                    bundleId: context.bundleId, name: name, title: context.windowTitle,
                    strength: model.chipStrength, tooltip: model.chipTooltip
                )
            }
        }
        .padding(.horizontal, 18)
        .frame(height: Self.searchHeight)
    }

    // Content

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.mode == .answer {
                        AnswerCard(line: model.answerLine)
                        // Without an answer the card already says "Here’s what matched:".
                        if model.answerText != nil, !model.rows.isEmpty {
                            SectionHeader(title: "Sources")
                        }
                    } else if let notice = model.notice {
                        Text(notice).font(.callout).foregroundStyle(.secondary).padding(16)
                    }
                    rowList
                }
                .padding(.bottom, 6)
            }
            .onChange(of: model.selection) { _, index in
                if model.rows.indices.contains(index) {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(model.rows[index].id) }
                }
            }
        }
    }

    private var rowList: some View {
        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
            if model.mode == .results, index == firstHit {
                SectionHeader(title: "From your memory")
            }
            BarRowView(
                row: row,
                selected: index == model.selection,
                hovered: hovered == row.id,
                context: model.context,
                mark: model.status.mark,
                windowRead: model.windowRead
            )
            .id(row.id)
            .contentShape(Rectangle())
            .onTapGesture {
                model.select(index)
                if let action = model.activate() { perform(action) }
            }
            .onHover { inside in
                if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
            }
        }
    }

    private var firstHit: Int? {
        model.rows.firstIndex { if case .hit = $0 { true } else { false } }
    }

    // Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.footerText).font(.caption).foregroundStyle(.secondary)
            if let action = model.footerAction {
                Button(action.title) { perform(.status(action)) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer()
            HStack(spacing: 14) { hints }
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    @ViewBuilder
    private var hints: some View {
        switch model.mode {
        case .home:
            KeyHint(keys: "⌘D", label: "Overview")
            KeyHint(keys: "⌘U", label: "You")
        case .results:
            if !model.answersAvailable {
                KeyHint(keys: "↩", label: "Search")
            }
            KeyHint(keys: "⇧⌘C", label: "Copy for your AI")
        case .answer:
            if model.answerText != nil {
                KeyHint(keys: "⌘C", label: "Copy Answer")
            }
            KeyHint(keys: "⇧⌘C", label: "Copy for your AI")
        }
    }
}

/// Liquid Glass on macOS 26; the native HUD material before it.
private struct GlassBackground: ViewModifier {
    let corner: CGFloat
    @Environment(\.askSolidBackground) private var solid

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        if solid {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
                .clipShape(shape)
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(VisualEffect())
                .overlay(shape.strokeBorder(.white.opacity(0.12)))
                .clipShape(shape)
        }
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label).font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

/// The window a question is about. At full strength only when Hippocampus
/// has read it (product critique 2).
private struct ContextChip: View {
    let bundleId: String?
    let name: String
    let title: String?
    let strength: Double
    /// Nil while it is not known whether the window was read.
    let tooltip: String?

    var body: some View {
        let chip = HStack(spacing: 6) {
            AppIcon(bundleId: bundleId).frame(width: 16, height: 16)
            Text(BarRowView.place(app: name, title: title))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 220)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .foregroundStyle(.secondary)
        .opacity(strength)
        if let tooltip {
            chip.help(tooltip)
        } else {
            chip
        }
    }
}

private struct AppIcon: View {
    let bundleId: String?
    var body: some View {
        if let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
        } else {
            Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }
}

private struct BarRowView: View {
    let row: BarRow
    let selected: Bool
    let hovered: Bool
    let context: FrontmostContext?
    let mark: HiMark.State
    let windowRead: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(.tertiary)
            }
            if selected {
                Text("↩").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.09) : hovered ? Color.primary.opacity(0.05) : .clear)
        )
        .padding(.horizontal, 6)
    }

    @ViewBuilder private var icon: some View {
        switch row {
        case .hit(let hit): AppIcon(bundleId: hit.appBundleId)
        case .thisWindow: AppIcon(bundleId: context?.bundleId)
        case .source: Image(systemName: "quote.opening").font(.system(size: 15)).foregroundStyle(.secondary)
        case .ask:
            HiMarkView(style: .brand, state: mark)
                .frame(height: 14)
                .foregroundStyle(.primary)
        case .suggestion(let s):
            Image(systemName: Self.symbol(for: s.kind)).font(.system(size: 16)).foregroundStyle(.secondary)
        }
    }

    static func symbol(for kind: String) -> String {
        switch kind {
        case "screen": "macwindow"
        case "resume": "arrow.uturn.backward.circle"
        case "related": "link"
        default: "circle"
        }
    }

    /// An app and a window title, one "·" between them.
    static func place(app: String, title: String?) -> String {
        guard let title, !title.isEmpty else { return app }
        return "\(app) · \(title)"
    }

    private var title: String {
        switch row {
        case .hit(let hit): hit.windowTitle?.isEmpty == false ? hit.windowTitle! : (hit.body.isEmpty ? "Untitled" : hit.body)
        case .thisWindow: "This window"
        case .source(let s): s.title?.isEmpty == false ? s.title! : s.app
        case .ask(let q): "Ask: “\(q)”"
        case .suggestion(let s): s.title
        }
    }

    private var subtitle: String? {
        switch row {
        case .hit(let hit):
            return hit.body
        case .thisWindow(let s):
            return Self.place(app: s.app, title: s.title)
        case .source(let s):
            return "\(s.app) · \(s.body)"
        case .ask:
            return windowRead ? "From this screen and what you’ve seen" : "From what you’ve seen"
        case .suggestion(let s):
            // The window in front, named as the chip names it.
            if s.kind == "screen", let app = context?.appName {
                return Self.place(app: app, title: context?.windowTitle)
            }
            return s.why
        }
    }

    private var trailing: String? {
        switch row {
        case .hit(let hit): Self.relative(hit.tsUs)
        case .source(let s), .thisWindow(let s): Self.relative(s.tsUs)
        default: nil
        }
    }

    static func relative(_ tsUs: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(tsUs) / 1_000_000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// The answer, "Thinking…" while it is written ("Searching…" where none can
/// be), why there is none, or what went wrong: never an empty card (spec-copy
/// M2 finding 7).
private struct AnswerCard: View {
    let line: AnswerLine?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch line {
            case .answer(let text):
                Text(text)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .thinking, .searching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(line == .thinking ? "Thinking…" : "Searching…").font(.callout).foregroundStyle(.secondary)
                }
            case .note(let text):
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
