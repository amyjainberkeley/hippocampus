import AppKit
import RecallUIKit
import SwiftUI

/// Ask: one field that searches as you type and answers a question with its
/// sources, and History under it while the field is empty (spec-recall S3 as
/// amended by both recall critiques; RULINGS W8, T12, T17).
struct AskPlace: View {
    @ObservedObject var model: AskViewModel
    let reader: BrainReader
    /// Moves on each time a command or a route asks for the cursor in the field.
    var fieldFocusRequest = 0
    /// Copies context about the question, with sources, for an AI tool.
    var contextExporter: @Sendable (String) async throws -> String
    var calendar: Calendar = .current
    var now: @Sendable () -> Date = { Date() }

    @FocusState private var fieldFocused: Bool
    @State private var openedSource: ScreenshotSelection?

    var body: some View {
        VStack(spacing: 0) {
            fieldRow
            Divider()
            if model.showsHistory {
                HistoryView(history: model.history, reader: reader, calendar: calendar, now: now)
            } else {
                VStack(spacing: 0) {
                    if model.answerState != .none {
                        AnswerCardView(
                            state: model.answerState,
                            contextExporter: contextExporter,
                            onOpenSource: open,
                            onRetry: { model.ask($0) },
                            onStop: { model.stopAsking() },
                            maxHeight: showsMatchesUnderAnswer ? 280 : nil
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
            }
        }
        .background(Color.brandBgPrimary)
        .background { askAnywayButton }
        .sheet(item: $openedSource) { selection in
            ScreenshotViewer(selection: selection, reader: reader)
        }
        .task(id: fieldFocusRequest &+ model.fieldFocusRequest) {
            // After the field is mounted (a new place or a sheet closing).
            await Task.yield()
            guard !Task.isCancelled else { return }
            fieldFocused = true
        }
        .onDisappear { model.disappear() }
    }

    /// Under an answer, the matches show only when there are some (or a
    /// filter could be narrowing them); otherwise the answer has the place.
    private var showsMatchesUnderAnswer: Bool {
        !model.search.hits.isEmpty || model.search.isSearching || model.showsFilters
            || model.search.filters.anyActive || model.search.isShowingFocusedEvent
    }

    // MARK: The field

    private var placeholder: String {
        model.answersAvailable == false ? UserFacingCopy.searchOnlyPlaceholder : UserFacingCopy.askPlaceholder
    }

    /// "↩ Ask" when Return asks, "⌘↩ Ask" when only ⌘Return does; nothing
    /// while answers cannot come on this Mac.
    private var keyHint: String? {
        guard model.answersAvailable != false,
              !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return model.looksLikeQuestion ? UserFacingCopy.askKeyHintReturn : UserFacingCopy.askKeyHintCommandReturn
    }

    private var isWorking: Bool {
        if case .thinking = model.answerState { return true }
        return model.search.isSearching
    }

    private var fieldRow: some View {
        HStack(spacing: MCI.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.brandFgMuted)
                .accessibilityHidden(true)
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(Color.brandFgPrimary)
                .focused($fieldFocused)
                .frame(minWidth: 0, maxWidth: .infinity)
                .onSubmit { submit(forceAsk: false) }
                .onKeyPress(.escape, phases: .down) { _ in
                    model.escape() == .ignored ? .ignored : .handled
                }
            if isWorking {
                ProgressView().controlSize(.small)
            }
            if let keyHint {
                Text(keyHint)
                    .mciFont(.caption)
                    .foregroundStyle(Color.brandFgMuted)
            }
            Button {
                model.showsFilters.toggle()
            } label: {
                Image(systemName: model.showsFilters || model.search.filters.anyActive
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.search.filters.anyActive ? Color.brandMint : Color.brandFgMuted)
            .help(UserFacingCopy.filtersAction)
            .accessibilityLabel(UserFacingCopy.filtersAction)
            .opacity(model.showsHistory ? 0 : 1)
            .disabled(model.showsHistory)
            if !model.query.isEmpty || model.search.isShowingFocusedEvent {
                Button {
                    model.clear()
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.brandFgMuted)
                }
                .buttonStyle(.plain)
                .help(UserFacingCopy.clearAction)
                .accessibilityLabel(UserFacingCopy.clearAction)
            }
        }
        .padding(.horizontal, MCI.Spacing.xl)
        .padding(.vertical, MCI.Spacing.l)
        .background(Color.brandBgSecondary)
    }

    /// ⌘Return asks whatever is typed (critique-recall-engineering finding 6).
    private var askAnywayButton: some View {
        Button(UserFacingCopy.askKeyHintCommandReturn) { submit(forceAsk: true) }
            .keyboardShortcut(.return, modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    private func submit(forceAsk: Bool) {
        if model.submit(forceAsk: forceAsk) == .focusFirstMatch, let first = model.search.hits.first {
            model.search.selectedHitId = first.id
        }
    }

    private func open(_ source: AskSource, among sources: [AskSource]) {
        let ids = sources.compactMap { UInt64(exactly: $0.eventId) }.filter { $0 > 0 }
        guard let id = UInt64(exactly: source.eventId), id > 0 else { return }
        openedSource = ScreenshotSelection(eventIDs: ids, initialID: id)
    }
}

/// The answer to the question in the field, or why there is none, with the
/// moments it came from (spec-recall S3; critique-recall-product finding 9).
struct AnswerCardView: View {
    let state: AskViewModel.AnswerState
    var contextExporter: @Sendable (String) async throws -> String
    let onOpenSource: (AskSource, [AskSource]) -> Void
    let onRetry: (String) -> Void
    let onStop: () -> Void
    /// The card scrolls past this height; nil lets it take the place.
    var maxHeight: CGFloat? = 280

    @State private var isCopying = false
    @State private var copyFailed = false

    var body: some View {
        ViewThatFits(in: .vertical) {
            card
            ScrollView { card }
        }
        .frame(maxHeight: maxHeight ?? .infinity, alignment: .top)
        .background(Color.brandBgPrimary)
        .alert(UserFacingCopy.copyFailedTitle, isPresented: $copyFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(UserFacingCopy.copyFailedBody)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.m) {
            switch state {
            case .none:
                EmptyView()
            case .thinking:
                HStack(spacing: MCI.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text(UserFacingCopy.askThinking)
                        .mciFont(.body)
                        .foregroundStyle(Color.brandFgSecondary)
                    Spacer(minLength: 0)
                    Button(UserFacingCopy.stopAction, action: onStop)
                        .buttonStyle(.borderless)
                }
            case let .answered(question, answer):
                if let text = answer.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    Text(verbatim: text)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.brandFgPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer(minLength: 0)
                        Button(UserFacingCopy.copyForYourAI) { copy(question) }
                            .buttonStyle(.bordered)
                            .disabled(isCopying)
                            .help(UserFacingCopy.copyForYourAIHelp)
                    }
                } else {
                    Text(UserFacingCopy.noAnswer(answer.unavailable))
                        .mciFont(.body)
                        .foregroundStyle(Color.brandFgSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !answer.sources.isEmpty {
                    sources(answer.sources)
                }
            case let .failed(question):
                HStack(spacing: MCI.Spacing.s) {
                    Text(UserFacingCopy.askFailed)
                        .mciFont(.body)
                        .foregroundStyle(Color.brandFgSecondary)
                    Spacer(minLength: 0)
                    Button(UserFacingCopy.tryAgainAction) { onRetry(question) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, MCI.Spacing.xl)
        .padding(.vertical, MCI.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sources(_ sources: [AskSource]) -> some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.xs) {
            Text(UserFacingCopy.sourcesHeading)
                .mciFont(.caption)
                .foregroundStyle(Color.brandFgSecondary)
            ForEach(sources) { source in
                Button {
                    onOpenSource(source, sources)
                } label: {
                    SourceRow(source: source)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func copy(_ question: String) {
        guard !isCopying else { return }
        isCopying = true
        Task {
            defer { isCopying = false }
            do {
                let packet = try await contextExporter(question)
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(packet, forType: .string) else {
                    copyFailed = true
                    return
                }
                ToastNotifier.shared.notify(UserFacingCopy.copiedToast)
            } catch {
                copyFailed = true
            }
        }
    }
}

/// One moment an answer came from: its window, its app and time, and one
/// line of what it said.
private struct SourceRow: View {
    let source: AskSource

    private var title: String {
        let title = source.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? source.app : title
    }

    private var line: String {
        let body = ReadableText.body(source.text)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return Formatters.snippet(body, maxLen: 160)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: MCI.Spacing.s) {
                Text(verbatim: title)
                    .mciFont(.bodyStrong)
                    .foregroundStyle(Color.brandFgPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(verbatim: UserFacingCopy.sourceLine(app: source.app, time: Formatters.clockTime(us: source.tsUs)))
                    .mciFont(.caption)
                    .foregroundStyle(Color.brandFgSecondary)
                    .lineLimit(1)
            }
            if !line.isEmpty {
                Text(verbatim: line)
                    .mciFont(.caption)
                    .foregroundStyle(Color.brandFgSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, MCI.Spacing.xs)
        .padding(.horizontal, MCI.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brandBgSecondary, in: RoundedRectangle(cornerRadius: MCI.Radius.s))
        .contentShape(Rectangle())
    }
}

/// History: the day's moments under the field while it is empty, with the day
/// moving back and forth (RULINGS W8).
struct HistoryView: View {
    @ObservedObject var history: TimelineViewModel
    let reader: BrainReader
    var calendar: Calendar = .current
    var now: @Sendable () -> Date = { Date() }

    private var today: MemoryDay { MemoryDay(date: now(), calendar: calendar) }
    private var day: MemoryDay { history.day ?? today }
    private var isToday: Bool { day == today }

    private var dayDate: Date {
        Date(timeIntervalSince1970: Double(day.startUs) / 1_000_000)
    }

    private var dayTitle: String {
        if isToday { return UserFacingCopy.todayAction }
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        return dayDate.formatted(style)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: MCI.Spacing.s) {
                Button { move(by: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help(UserFacingCopy.previousDay)
                    .accessibilityLabel(UserFacingCopy.previousDay)
                Text(verbatim: dayTitle)
                    .mciFont(.bodyStrong)
                    .foregroundStyle(Color.brandFgPrimary)
                Button { move(by: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(isToday)
                    .help(UserFacingCopy.nextDay)
                    .accessibilityLabel(UserFacingCopy.nextDay)
                Spacer(minLength: 0)
                if history.range != nil {
                    Button(UserFacingCopy.wholeDayAction) { Task { await history.showWholeDay() } }
                        .buttonStyle(.borderless)
                }
                if !isToday {
                    Button(UserFacingCopy.todayAction) { Task { await history.show(day: today) } }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, MCI.Spacing.xl)
            .padding(.vertical, MCI.Spacing.s)
            Divider()
            TimelineView(viewModel: history, reader: reader, isToday: isToday, calendar: calendar)
        }
    }

    private func move(by days: Int) {
        guard let date = calendar.date(byAdding: .day, value: days, to: dayDate) else { return }
        let target = MemoryDay(date: date, calendar: calendar)
        guard target.startUs <= today.startUs else { return }
        Task { await history.show(day: target) }
    }
}
