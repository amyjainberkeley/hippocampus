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
    /// While a note after Ask {Tool} shows, the panel stays up over the
    /// tool that opened, then goes (SPEC 5.3.8).
    private var noteUntil: Date?
    private var noteTask: Task<Void, Never>?
    /// When a `hippocampus://ask` link last opened Ask (RULINGS S12).
    private var linkOpenedAt: Date?
    /// A show asked for before Ask was set up: a link that launched the app
    /// arrives before the launch sets Ask up. Kept, with its question, and
    /// shown once it is.
    private var heldShow: (question: String?, opening: AskPanelDismissal.Opening)?

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
        model.perform = { [weak self] action in self?.perform(action) }
        if let held = heldShow {
            heldShow = nil
            show(asking: held.question, from: held.opening)
        }
    }

    /// The key again closes it; it does not jump screens. Only the key and
    /// Esc close Ask this way (RULINGS S12).
    func toggle() {
        if AskPanelDismissal.closes(.key, visible: panel?.isVisible == true) { hide() } else { show(from: .key) }
    }

    /// The menu and a link only ever show Ask, even when it is up already
    /// (RULINGS S12): a second link never hides an answer on its way.
    func show(asking question: String? = nil, from opening: AskPanelDismissal.Opening = .menu) {
        guard let model else {
            heldShow = (question, opening)
            return
        }
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
                // Read the window in front once now, past the reader's rest.
                supervisor.requestFreshRead()
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
        noteTask?.cancel()
        noteTask = nil
        noteUntil = nil
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
            heightChanged: { [weak self] height in self?.resize(height: height) },
            noteAction: { [weak self] action in self?.performNoteAction(action) }
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
                case .text(let text): self?.copyForYourAI(text)
                case .failed: model.showFlash(HandoffCopy.couldNotCopy)
                case .nothing: model.showFlash(HandoffCopy.nothingToSend)
                case .dropped: break
                }
            }
        case .status(let action):
            statusAction?(action)
        case .handoff(let plan, let tool):
            deliver(plan, tool: tool)
        }
    }

    /// Ask {Tool}: copy by the clipboard rules and open, then the note in the
    /// footer for six seconds, over the tool that opened (SPEC 5.3.8).
    private func deliver(_ plan: HandoffPlan, tool: AskTool) {
        guard let model else { return }
        var note = plan.note
        for step in plan.steps {
            switch step {
            case .copy(let text):
                guard ClipboardHygiene.copy(text) else {
                    model.showFlash(HandoffCopy.couldNotCopy)
                    return
                }
            case .open(let url):
                if !NSWorkspace.shared.open(url), let text = plan.fallbackCopy {
                    ClipboardHygiene.copy(text)
                    note = HandoffDelivery.couldNotOpen(tool)
                }
            }
        }
        showNote(note)
    }

    private func showNote(_ note: HandoffNote) {
        guard let model else { return }
        model.showNote(note)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: note.spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        noteUntil = Date().addingTimeInterval(6)
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// The note's button.
    private func performNoteAction(_ action: HandoffNote.Action) {
        guard let model else { return }
        switch action {
        case .copyInstead(let text):
            ClipboardHygiene.copy(text)
            showNote(HandoffNote(text: HandoffCopy.copied))
        case .copyFullVersion:
            Task { [weak self] in
                switch await model.copyFullVersion() {
                case .text(let text):
                    ClipboardHygiene.copy(text)
                    self?.showNote(HandoffNote(text: HandoffCopy.copied))
                default:
                    model.showFlash(HandoffCopy.couldNotCopy)
                }
            }
        case .openTerminal(let folder):
            if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    /// Copy for Your AI: by the clipboard rules, then "Copied" a moment
    /// and Ask closes.
    private func copyForYourAI(_ text: String) {
        guard ClipboardHygiene.copy(text) else {
            model?.showFlash(HandoffCopy.couldNotCopy)
            return
        }
        model?.showFlash(HandoffCopy.copied)
        closeAfterCopy?.cancel()
        closeAfterCopy = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// "Copied" in the footer for a moment, then Ask closes.
    private func copy(_ text: String) {
        ClipboardHygiene.copyToKeep(text)
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
        // The tool Ask {Tool} opened came forward: the note stays its six
        // seconds over it.
        if let noteUntil, Date() < noteUntil { return }
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
    var noteAction: (HandoffNote.Action) -> Void = { _ in }
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
        !model.rows.isEmpty || model.mode == .answer || model.notice != nil || model.stage != nil
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
                .onKeyPress(.return, phases: .down) { press in
                    // ↩ opens; ⌘↩ asks the person's AI tool; ⌥↩ resumes an
                    // item (SPEC-DELTA 4).
                    if press.modifiers.contains(.command) {
                        model.askAITool()
                    } else if press.modifiers.contains(.option) {
                        if let action = model.resumeSelected() { perform(action) }
                    } else if let action = model.activate() {
                        perform(action)
                    }
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

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .firstUse(let pending, let tool, let card, let includeAboutMe):
            FirstUseCard(
                pending: pending, tool: tool, card: card, includeAboutMe: includeAboutMe,
                toggleAboutMe: { model.toggleIncludeAboutMe() },
                cancel: { model.cancelHandoff() },
                open: { model.confirmFirstUse() }
            )
        case .sending(let tool):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(HandoffCopy.askHint(tool.name) + "…").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .picking:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(HandoffCopy.pickTitle).font(.system(size: 13.5, weight: .semibold))
                        Text(HandoffCopy.pickDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                    rowList
                }
                .padding(.bottom, 6)
            }
        case nil:
            results
        }
    }

    private var results: some View {
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
            if model.mode == .results, model.stage == nil, let header = header(before: index) {
                SectionHeader(title: header)
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

    /// "Working On", "Web Pages" and "From your memory", each over its
    /// first row.
    private func header(before index: Int) -> String? {
        let rows = model.rows
        func kind(_ row: BarRow) -> Int {
            switch row {
            case .item: 1
            case .page: 2
            case .hit: 3
            default: 0
            }
        }
        let current = kind(rows[index])
        guard current != 0, index == 0 || kind(rows[index - 1]) != current else { return nil }
        switch current {
        case 1: return HandoffCopy.workingOnGroup
        case 2: return HandoffCopy.webPagesGroup
        default: return HandoffCopy.momentsGroup
        }
    }

    // Footer

    @ViewBuilder
    private var footer: some View {
        if let note = model.note {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.text).font(.caption).foregroundStyle(.primary)
                    ForEach(note.lines, id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let action = note.action {
                    Button(action.title) { noteAction(action) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 34)
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 10) {
                Text(model.footerText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let action = model.footerAction {
                    Button(model.footerActionTitle ?? action.title) { perform(.status(action)) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Spacer()
                HStack(spacing: 14) {
                    ForEach(model.keyHints, id: \.keys) { hint in
                        KeyHint(keys: hint.keys, label: hint.label)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
    }
}

/// The first time a tool is asked, one quiet card (SPEC 5.3.8): what opens,
/// that nothing is sent until the person presses send there, and who
/// receives it, over the exact message, word for word.
private struct FirstUseCard: View {
    let pending: PendingAsk
    let tool: InstalledTool
    let card: SendCard?
    let includeAboutMe: Bool
    let toggleAboutMe: () -> Void
    let cancel: () -> Void
    let open: () -> Void

    private var isProject: Bool {
        if case .item(let item) = pending.source, tool.tool == .claudeCode { return item.kind == "code" }
        return false
    }

    private var title: String {
        if case .item(let item) = pending.source, isProject { return HandoffCopy.firstUseTitleProject(item.name) }
        return HandoffCopy.firstUseTitle(tool.tool.name)
    }

    private var body_: String {
        tool.tool.isPasted ? HandoffCopy.firstUseBodyPasted(tool.tool.name) : HandoffCopy.firstUseBody(tool.tool.name)
    }

    private var openTitle: String {
        tool.tool.isPasted ? HandoffCopy.copyAndOpen(tool.tool.name) : HandoffCopy.openTool(tool.tool.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ToolIcon(tool: tool, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(body_).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if isProject, let folder = card?.folder {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(HandoffCopy.firstUseFolder(folder)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(HandoffCopy.whatGoes).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let card {
                    Text(HandoffCopy.size(words: card.words, moments: max(card.included.count, 1)))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Group {
                if let card {
                    ScrollView {
                        Text(MessagePreview.attributed(card.message))
                            .font(.system(size: 11, design: .monospaced))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
                }
            }
            .frame(height: 150)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            if card?.peopleMessages == true {
                Text(HandoffCopy.people).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            HStack {
                Toggle(HandoffCopy.includeAboutMe, isOn: Binding(get: { includeAboutMe }, set: { _ in toggleAboutMe() }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
                Spacer()
                Button(HandoffCopy.cancel, action: cancel)
                Button(openTitle, action: open)
                    .buttonStyle(.borderedProminent)
                    .disabled(card == nil)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

/// The message as the sheet shows it: word for word, with heading marks and
/// fences in a quieter grey so the moment's own words read first.
enum MessagePreview {
    static func attributed(_ message: String) -> AttributedString {
        var out = AttributedString()
        let lines = message.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("```") {
                var mark = AttributedString(line)
                mark.foregroundColor = .secondary.opacity(0.7)
                out += mark
            } else if let space = line.firstIndex(of: " "), line[..<space].allSatisfy({ $0 == "#" }), !line[..<space].isEmpty {
                var mark = AttributedString(String(line[...space]))
                mark.foregroundColor = .secondary.opacity(0.7)
                out += mark
                out += AttributedString(String(line[line.index(after: space)...]))
            } else {
                out += AttributedString(line)
            }
            if index < lines.count - 1 { out += AttributedString("\n") }
        }
        return out
    }
}

/// An AI tool's own app icon, or a quiet tile with its first letter when its
/// app isn't on this Mac.
private struct ToolIcon: View {
    let tool: InstalledTool
    let size: CGFloat

    var body: some View {
        if let app = tool.appURL, FileManager.default.fileExists(atPath: app.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable().interpolation(.high)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    Image(systemName: tool.tool == .claudeCode ? "terminal" : "sparkle")
                        .font(.system(size: size * 0.45, weight: .medium))
                        .foregroundStyle(.secondary)
                )
                .frame(width: size, height: size)
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
            // An app that isn't on this Mac: a quiet tile with its initial.
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: proxy.size.width * 0.24, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .overlay(
                        Text(bundleId.map { String(AppNames.name($0).prefix(1)).uppercased() } ?? "")
                            .font(.system(size: proxy.size.width * 0.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    )
            }
            .padding(1)
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
        case .item(let item):
            Image(systemName: Self.kindSymbol(item.kind))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .page(let page): AppIcon(bundleId: page.app)
        case .tool(let tool): ToolIcon(tool: tool, size: 26)
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

    /// A Working On item's kind, as the sidebar draws it.
    static func kindSymbol(_ kind: String) -> String {
        switch kind {
        case "code": "chevron.left.forwardslash.chevron.right"
        case "design": "pencil"
        case "spreadsheet": "tablecells"
        default: "doc.text"
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
        case .item(let item): item.name
        case .page(let page): page.title
        case .tool(let tool): tool.tool.name
        // What History's row calls the moment, not its raw window title.
        case .hit(let hit): hit.shownTitle
        case .thisWindow: "This window"
        case .source(let s): s.title?.isEmpty == false ? s.title! : s.app
        case .ask(let q): "Ask: “\(q)”"
        case .suggestion(let s): s.title
        }
    }

    private var subtitle: String? {
        switch row {
        case .item(let item):
            let apps = AppNames.spoken(item.apps.map(AppNames.name))
            return apps.isEmpty ? HandoffCopy.kind(item.kind) : "\(HandoffCopy.kind(item.kind)) · \(apps)"
        case .page(let page):
            return [page.host, AppNames.name(page.app)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .tool:
            return nil
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
        case .item(let item): item.lastUs > 0 ? Self.relative(item.lastUs) : nil
        case .page(let page): page.lastUs > 0 ? Self.relative(page.lastUs) : nil
        case .hit(let hit): Self.relative(hit.tsUs)
        case .source(let s), .thisWindow(let s): Self.relative(s.tsUs)
        case .suggestion(let s): s.tsUs.map(Self.relative)
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

/// An app's name from its bundle id: the app's own when it is on this Mac,
/// else the names people know, else the last part of the id.
enum AppNames {
    static let known: [String: String] = [
        "com.microsoft.VSCode": "VS Code", "com.apple.Terminal": "Terminal", "com.google.Chrome": "Chrome",
        "com.apple.Safari": "Safari", "com.figma.Desktop": "Figma", "com.apple.Notes": "Notes",
        "com.tinyspeck.slackmacgap": "Slack", "com.todesktop.230313mzl4w4u92": "Cursor",
        "company.thebrowser.Browser": "Arc", "org.mozilla.firefox": "Firefox", "com.apple.mail": "Mail",
        "com.apple.iWork.Numbers": "Numbers", "com.apple.iWork.Pages": "Pages", "com.apple.Preview": "Preview",
        "com.anthropic.claudefordesktop": "Claude", "com.openai.chat": "ChatGPT", "dev.zed.Zed": "Zed",
        "com.apple.dt.Xcode": "Xcode", "notion.id": "Notion", "us.zoom.xos": "Zoom",
    ]

    static func name(_ bundleId: String) -> String {
        if let known = known[bundleId] { return known }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleId.split(separator: ".").last.map(String.init) ?? bundleId
    }

    /// "VS Code and Terminal"; "Chrome, Slack and Notes".
    static func spoken(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}
