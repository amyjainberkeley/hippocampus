import AppKit
import RecallUIKit
import SwiftUI

/// The first row of the window's content (SPEC 2.1, 2.8): Back and Forward,
/// then the field on every memory page. About You, AI Tools and Privacy have
/// no field. While the sidebar is hidden the row also carries the window's
/// controls and the sidebar button, as the sidebar's top does.
struct WindowTopBar: View {
    let page: WindowPage
    let canGoBack: Bool
    let canGoForward: Bool
    /// The sidebar is hidden: the row starts with the window's controls and
    /// the button that shows it.
    var sidebarHidden = false
    var drawsWindowControls = false
    var isDemoMemory = false
    @ObservedObject var ask: AskViewModel
    var fieldFocused: FocusState<Bool>.Binding
    var back: () -> Void = {}
    var forward: () -> Void = {}
    var toggleSidebar: () -> Void = {}
    /// ⌘↩: Ask your AI tool with the typed question (SPEC 5.3, wired by the
    /// handoff); nil asks on this Mac until it is.
    var askYourAI: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if sidebarHidden {
                HStack(spacing: 14) {
                    if drawsWindowControls { WindowTrafficLights() }
                    SidebarToggleButton(action: toggleSidebar, hidesSidebar: false)
                }
                .padding(.leading, 8)
                .padding(.trailing, 6)
                if isDemoMemory { DemoTag() }
            }
            HStack(spacing: 0) {
                arrow("chevron.left", label: NavigationCopy.back, enabled: canGoBack, action: back)
                arrow("chevron.right", label: NavigationCopy.forward, enabled: canGoForward, action: forward)
            }
            if page.hasField {
                field
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .frame(height: 52)
        .background(MCI.Color.surface)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            Rectangle().fill(MCI.Color.hairline).frame(height: 1)
        }
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarHoverButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.32)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: The field

    private var placeholder: String {
        if page.isWorkingOn { return NavigationCopy.workingOnPlaceholder }
        return ask.answersAvailable == false ? UserFacingCopy.searchOnlyPlaceholder : UserFacingCopy.askPlaceholder
    }

    private var isWorking: Bool {
        if case .thinking = ask.answerState { return true }
        return ask.search.isSearching
    }

    private var field: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(MCI.Color.foregroundMuted)
                .accessibilityHidden(true)
            TextField("", text: $ask.query, prompt: Text(placeholder).foregroundColor(MCI.Color.placeholder))
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(MCI.Color.foreground)
                .focused(fieldFocused)
                .frame(minWidth: 0, maxWidth: .infinity)
                .onSubmit { submit(forceAsk: false) }
                .onKeyPress(.escape, phases: .down) { _ in
                    ask.escape() == .ignored ? .ignored : .handled
                }
                .accessibilityLabel(placeholder)
            if isWorking {
                ProgressView().controlSize(.small)
            }
            if ask.showsMatches {
                Button {
                    ask.showsFilters.toggle()
                } label: {
                    Image(systemName: ask.showsFilters || ask.search.filters.anyActive
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ask.search.filters.anyActive ? MCI.Color.accent : MCI.Color.foregroundMuted)
                .help(UserFacingCopy.filtersAction)
                .accessibilityLabel(UserFacingCopy.filtersAction)
            }
            if !ask.query.isEmpty || ask.search.isShowingFocusedEvent {
                Button {
                    ask.clear()
                    fieldFocused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(MCI.Color.foregroundMuted)
                }
                .buttonStyle(.plain)
                .help(UserFacingCopy.clearAction)
                .accessibilityLabel(UserFacingCopy.clearAction)
            }
            Text(NavigationCopy.findKey)
                .font(.system(size: 12))
                .foregroundStyle(MCI.Color.foregroundMuted)
                .accessibilityHidden(true)
        }
        .padding(.leading, 8)
        .frame(height: 36)
        .background { keys }
    }

    /// ⌥↩ asks on this Mac whatever is typed; ⌘↩ hands it to your AI tool
    /// (SPEC 2.8, 2.10).
    private var keys: some View {
        ZStack {
            Button("") { submit(forceAsk: true) }
                .keyboardShortcut(.return, modifiers: .option)
            Button("") {
                let question = ask.query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !question.isEmpty else { return }
                if let askYourAI {
                    askYourAI(question)
                } else {
                    submit(forceAsk: true)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func submit(forceAsk: Bool) {
        if ask.submit(forceAsk: forceAsk) == .focusFirstMatch, let first = ask.search.hits.first {
            ask.search.selectedHitId = first.id
        }
    }
}

/// Results take the page's place while the field holds something (SPEC
/// 2.8): the answer card on top, then the matches, drawn as History rows.
/// Esc or ⌘[ brings the page back.
struct FieldResults: View {
    @ObservedObject var model: AskViewModel
    let reader: BrainReader
    var contextExporter: @Sendable (String) async throws -> String

    @State private var openedSource: ScreenshotSelection?

    var body: some View {
        VStack(spacing: 0) {
            if model.answerState != .none {
                AnswerCardView(
                    state: model.answerState,
                    contextExporter: contextExporter,
                    onOpenSource: open,
                    onRetry: { model.ask($0) },
                    onStop: { model.stopAsking() },
                    maxHeight: showsMatchesUnderAnswer ? 280 : nil,
                    reader: reader
                )
                if showsMatchesUnderAnswer { Divider() }
            }
            if model.answerState == .none || showsMatchesUnderAnswer {
                SearchView(
                    viewModel: model.search,
                    reader: reader,
                    showsFilters: model.showsFilters,
                    showsNoMatches: model.showsNoMatches,
                    heading: model.answerState == .none ? nil : UserFacingCopy.moreFromYourMemory
                )
            }
        }
        .background(MCI.Color.background)
        .sheet(item: $openedSource) { selection in
            ScreenshotViewer(selection: selection, reader: reader)
        }
    }

    private var showsMatchesUnderAnswer: Bool {
        !model.search.hits.isEmpty || model.search.isSearching || model.showsFilters
            || model.search.filters.anyActive || model.search.isShowingFocusedEvent
    }

    private func open(_ source: AskSource, among sources: [AskSource]) {
        let ids = sources.compactMap { UInt64(exactly: $0.eventId) }.filter { $0 > 0 }
        guard let id = UInt64(exactly: source.eventId), id > 0 else { return }
        openedSource = ScreenshotSelection(eventIDs: ids, initialID: id)
    }
}

/// Sets up the live window's frame once it exists: no title bar band, the
/// content under it, and the window's controls centred in a 52 pt top as
/// the prototype draws them. Off-screen pictures have no such window.
struct WindowChromeConfigurator: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            WindowChromeConfigurator.configure(window)
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}

    @MainActor
    static func configure(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // An empty unified toolbar gives the title bar a 52 pt band with the
        // window's controls centred in it; nothing is drawn in it, and the
        // content under it takes every click.
        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: "ai.hippocampus.window.top")
            toolbar.showsBaselineSeparator = false
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
        }
        window.toolbarStyle = .unified
    }
}
