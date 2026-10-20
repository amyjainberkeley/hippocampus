// SPDX-License-Identifier: Apache-2.0
//
// PanelHandoff.swift — the Ask panel as Spotlight for your memory
// (SPEC-DELTA 4, SPEC 5.3.9): as you type it finds Working On items, pages
// and moments, and each result has keys: ↩ opens it, ⌘↩ asks the person's
// AI tool about it, ⌥↩ resumes an item. ⌘↩ with a question asks the tool
// with the question and the top matches; with nothing typed, about the
// window in front. ⇧⌘C copies the same message for any AI. Every message
// is made by the one builder (`mci-agent send-card`), so the panel and the
// window always say the same.

import Foundation

/// What the panel needs to hand context to AI tools.
public struct PanelHandoff: Sendable {
    public var agent: PanelAgent
    /// The AI tools on this Mac, in the menu's order.
    public var tools: @Sendable () -> [InstalledTool]
    public var choices: HandoffChoices
    /// The person's home folder, for a project folder written from `~`.
    public var home: String

    public init(agent: PanelAgent, tools: @escaping @Sendable () -> [InstalledTool], choices: HandoffChoices, home: String) {
        self.agent = agent
        self.tools = tools
        self.choices = choices
        self.home = home
    }

    /// No tools and no agent: for previews that draw fixtures.
    public static func none(choices: HandoffChoices = .ephemeral()) -> PanelHandoff {
        PanelHandoff(agent: NoPanelAgent(), tools: { [] }, choices: choices, home: NSHomeDirectory())
    }
}

/// What ⌘↩ or ⇧⌘C hands over, by ids only: the builder reads the rest just
/// before anything opens.
public struct PendingAsk: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Moments, newest first, with the one picked.
        case moments([UInt64], selected: UInt64?)
        /// A Working On item, with its moments as the fallback.
        case item(PanelItem)
        /// A question, with the moments its answer cited or its top matches.
        case question(String, [UInt64])
    }

    public var source: Source

    public init(_ source: Source) {
        self.source = source
    }

    /// How many moments it names, for "About 151 words · 1 moment".
    public var momentCount: Int {
        switch source {
        case .moments(let ids, _): ids.count
        case .item: 1
        case .question(_, let ids): ids.count
        }
    }

    /// The request for `to`.
    public func request(to: String, appInstalled: Bool?, includeAboutMe: Bool, full: Bool = false) -> SendCardRequest {
        var request = SendCardRequest(to: to, includeAboutMe: includeAboutMe, appInstalled: appInstalled, full: full)
        switch source {
        case .moments(let ids, let selected):
            request.moments = ids
            request.selected = selected
        case .item(let item):
            request.item = item.id
            request.moments = item.moments
        case .question(let question, let ids):
            request.question = question
            request.moments = ids
        }
        return request
    }
}

/// Where a ⌘↩ is in the panel: choosing a tool, the one-time sheet for a
/// tool, or waiting for the builder.
public enum HandoffStage: Equatable, Sendable {
    case picking(PendingAsk)
    case firstUse(PendingAsk, InstalledTool, card: SendCard?, includeAboutMe: Bool)
    case sending(AskTool)
}

/// One key and what it does, for the footer.
public struct KeyHintItem: Equatable, Sendable {
    public let keys: String
    public let label: String

    public init(_ keys: String, _ label: String) {
        self.keys = keys
        self.label = label
    }
}

public extension CommandBarModel {
    // MARK: What ⌘↩ hands over

    /// The thing ⌘↩ and ⇧⌘C hand over now: the selected result, else the
    /// typed question with its top matches, else the answer's question with
    /// its sources, else the window in front when Hippocampus has read it.
    func pendingAsk() -> PendingAsk? {
        if rows.indices.contains(selection) {
            switch rows[selection] {
            case .item(let item): return PendingAsk(.item(item))
            case .page(let page):
                guard let newest = page.moments.first else { return nil }
                return PendingAsk(.moments([newest], selected: newest))
            case .hit(let hit): return PendingAsk(.moments([hit.eventId], selected: hit.eventId))
            case .source(let source), .thisWindow(let source):
                guard source.eventId > 0 else { return nil }
                let id = UInt64(source.eventId)
                return PendingAsk(.moments([id], selected: id))
            case .ask, .suggestion, .tool:
                break
            }
        }
        switch mode {
        case .answer:
            guard let question = askedQuestion else { return nil }
            let ids = (answer?.sources ?? []).compactMap { $0.eventId > 0 ? UInt64($0.eventId) : nil }
            return PendingAsk(.question(question, ids))
        case .results:
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return PendingAsk(.question(text, hits.prefix(8).map(\.eventId)))
        case .home:
            guard windowRead, let id = readEventIdForHandoff else { return nil }
            return PendingAsk(.moments([id], selected: id))
        }
    }

    /// The tool ⌘↩ opens, when it is on this Mac.
    var askTool: InstalledTool? {
        guard let last = handoff.choices.lastTool else { return nil }
        return installedTools.first { $0.tool == last }
    }

    /// ⌘↩: Ask {Tool}. The first time, choose a tool; the first time for a
    /// tool, its one-time sheet; then the tool opens with the message in its
    /// box. In the sheet, ⌘↩ is its default button.
    func askAITool() {
        if case .firstUse = stage {
            confirmFirstUse()
            return
        }
        if case .picking = stage {
            if rows.indices.contains(selection), case .tool(let tool) = rows[selection] { choose(tool) }
            return
        }
        guard case nil = stage else { return }
        guard let pending = pendingAsk() else {
            showFlash(HandoffCopy.nothingToSend)
            return
        }
        installedTools = handoff.tools()
        guard !installedTools.isEmpty else {
            // No AI tool on this Mac: Copy for Your AI.
            perform?(.copyForAI)
            return
        }
        guard let tool = askTool else {
            stage = .picking(pending)
            selection = 0
            return
        }
        begin(pending, with: tool)
    }

    /// A tool picked in the panel: it becomes the one ⌘↩ opens.
    func choose(_ tool: InstalledTool) {
        guard case .picking(let pending) = stage else { return }
        handoff.choices.lastTool = tool.tool
        stage = nil
        begin(pending, with: tool)
    }

    /// The one-time sheet's Open button.
    func confirmFirstUse() {
        guard case .firstUse(let pending, let tool, _, let includeAboutMe) = stage else { return }
        handoff.choices.markTold(tool.tool)
        send(pending, to: tool, includeAboutMe: includeAboutMe)
    }

    /// The sheet's checkbox: the message is made again with it.
    func toggleIncludeAboutMe() {
        guard case .firstUse(let pending, let tool, _, let include) = stage else { return }
        stage = .firstUse(pending, tool, card: nil, includeAboutMe: !include)
        preview(pending, tool: tool, includeAboutMe: !include)
    }

    /// Esc in a stage, or Cancel: nothing opens.
    func cancelHandoff() {
        handoffTask?.cancel()
        handoffTask = nil
        stage = nil
        selection = mode == .answer ? -1 : 0
    }

    /// ⌥↩: resume the selected Working On item (SPEC-DELTA 3); on the field
    /// or its Ask row, ask on this Mac.
    func resumeSelected() -> BarAction? {
        guard stage == nil else { return nil }
        if rows.indices.contains(selection), case .item(let item) = rows[selection] {
            return .openWindow(tab: HippocampusURLRoute.resumeTab(item: item.id))
        }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .results, !text.isEmpty, selection <= 0 {
            ask(text)
        }
        return nil
    }

    // MARK: Sending

    private func begin(_ pending: PendingAsk, with tool: InstalledTool) {
        if handoff.choices.wasTold(tool.tool) {
            send(pending, to: tool, includeAboutMe: false)
            return
        }
        stage = .firstUse(pending, tool, card: nil, includeAboutMe: false)
        preview(pending, tool: tool, includeAboutMe: false)
    }

    /// The message the sheet shows, word for word.
    private func preview(_ pending: PendingAsk, tool: InstalledTool, includeAboutMe: Bool) {
        let agent = handoff.agent
        let request = pending.request(to: tool.tool.rawValue, appInstalled: tool.hasApp, includeAboutMe: includeAboutMe)
        handoffTask?.cancel()
        handoffTask = Task { [weak self] in
            let card = try? await agent.card(request)
            guard !Task.isCancelled, let self,
                  case .firstUse(let current, let currentTool, _, let currentInclude) = self.stage,
                  current == pending, currentTool == tool, currentInclude == includeAboutMe else { return }
            self.stage = .firstUse(pending, tool, card: card, includeAboutMe: includeAboutMe)
        }
    }

    /// Ask the builder just before anything opens, then open: a second press
    /// within 2 seconds is ignored, and closing the panel before it is ready
    /// opens nothing, ever (SPEC 5.3.8).
    private func send(_ pending: PendingAsk, to tool: InstalledTool, includeAboutMe: Bool) {
        let now = self.now()
        if let last = lastSendAt, now.timeIntervalSince(last) < 2 { return }
        lastSendAt = now
        stage = .sending(tool.tool)
        let open = currentOpenID
        let agent = handoff.agent
        let home = handoff.home
        let request = pending.request(to: tool.tool.rawValue, appInstalled: tool.hasApp, includeAboutMe: includeAboutMe)
        handoffTask?.cancel()
        handoffTask = Task { [weak self] in
            do {
                let card = try await agent.card(request)
                guard !Task.isCancelled, let self, self.isPanelOpen, self.currentOpenID == open else { return }
                self.stage = nil
                let plan = HandoffDelivery.plan(card: card, tool: tool.tool, installed: tool, home: home)
                self.lastCard = card
                self.lastRequest = request
                self.perform?(.handoff(plan, tool.tool))
            } catch {
                guard !Task.isCancelled, let self, self.isPanelOpen, self.currentOpenID == open else { return }
                self.stage = nil
                self.showFlash((error as? SendCardError) == .locked ? HandoffCopy.locked : HandoffCopy.couldNotCopy)
            }
        }
    }

    /// Copy Full Version: the whole message, copied.
    func copyFullVersion() async -> CopyForAIResult {
        guard var request = lastRequest else { return .failed }
        request.to = "copy"
        request.full = true
        guard let card = try? await handoff.agent.card(request), !card.message.isEmpty else { return .failed }
        return .text(card.message)
    }

    /// Shows a note in the footer for its six seconds.
    func showNote(_ note: HandoffNote?) {
        self.note = note
        if note != nil { flash = nil }
    }

    // MARK: The footer

    /// The keys the footer shows for what is selected now.
    var keyHints: [KeyHintItem] {
        let toolName = askTool?.tool.name ?? handoff.choices.lastTool?.name
        let askHint = KeyHintItem("⌘↩", HandoffCopy.askHint(toolName))
        switch stage {
        case .picking:
            return [KeyHintItem("↩", HandoffCopy.chooseHint), KeyHintItem("esc", HandoffCopy.cancel)]
        case .firstUse(_, let tool, _, _):
            let open = tool.tool.isPasted && tool.hasApp
                ? HandoffCopy.copyAndOpen(tool.tool.name) : HandoffCopy.openTool(tool.tool.name)
            return [KeyHintItem("↩", open), KeyHintItem("esc", HandoffCopy.cancel)]
        case .sending:
            return []
        case nil:
            break
        }
        let selected = rows.indices.contains(selection) ? rows[selection] : nil
        switch mode {
        case .home:
            var hints = [KeyHintItem("⌘D", HandoffCopy.todayHint), KeyHintItem("⌘U", HandoffCopy.aboutYouHint)]
            if windowRead, readEventIdForHandoff != nil { hints.insert(askHint, at: 0) }
            return hints
        case .results:
            switch selected {
            case .item?:
                return [KeyHintItem("↩", HandoffCopy.openHint), askHint, KeyHintItem("⌥↩", HandoffCopy.resumeHint)]
            case .page?, .hit?:
                return [KeyHintItem("↩", HandoffCopy.openHint), askHint]
            default:
                if !answersAvailable { return [KeyHintItem("↩", HandoffCopy.searchHint), askHint] }
                return [KeyHintItem("↩", HandoffCopy.askHereHint), askHint]
            }
        case .answer:
            var hints = [askHint]
            if answerText != nil { hints.append(KeyHintItem("⌘C", HandoffCopy.copyAnswer)) }
            hints.append(KeyHintItem("⇧⌘C", HandoffCopy.copyForYourAI))
            return hints
        }
    }

    // MARK: Finding items and pages as you type

    /// Load what Working On and Web Pages list, once a minute at most, while
    /// the panel opens.
    func loadWork() {
        if let loaded = workLoadedAt, now().timeIntervalSince(loaded) < Self.keepWorkFor { return }
        workLoadedAt = now()
        let agent = handoff.agent
        Task { [weak self] in
            guard let work = try? await agent.work() else { return }
            guard let self else { return }
            self.work = work
            self.refreshMatches()
        }
    }

    /// The items and pages whose names hold what is typed, best first: every
    /// word (as the start of a word, or anywhere in a longer one) for a
    /// search; any of its words, as the start of a word, for a question, so
    /// "why is trailhead failing?" still finds trailhead-shop.
    static func matches(_ query: String, in work: PanelWork) -> (items: [PanelItem], pages: [PanelPage]) {
        let words = searchWords(query)
        guard !words.isEmpty else { return ([], []) }
        let question = reads(asQuestion: query)
        func score(_ text: String) -> Int? {
            let folded = fold(text)
            let parts = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            var total = 0
            for word in words {
                if folded.hasPrefix(word) {
                    total += 3
                } else if parts.contains(where: { $0.hasPrefix(word) }) {
                    total += 2
                } else if !question, folded.contains(word) {
                    total += 1
                } else if !question {
                    return nil
                }
            }
            return total > 0 ? total : nil
        }
        let items = work.items
            .compactMap { item in score(item.name).map { (item, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastUs > $1.0.lastUs }
            .prefix(itemRowLimit).map(\.0)
        let pages = work.pages
            .compactMap { page in score(page.title + " " + (page.host ?? "")).map { (page, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastUs > $1.0.lastUs }
            .prefix(pageRowLimit).map(\.0)
        return (Array(items), Array(pages))
    }

    /// A question: it ends with "?" or starts with a question word.
    static func reads(asQuestion query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        let first = fold(trimmed).split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return ["what", "why", "how", "when", "where", "who", "which", "did", "does", "do", "is", "was",
                "are", "can", "could", "should", "tell", "summarize", "summarise"].contains(first)
    }

    /// The words a search finds by: lower-cased, without accents, and without
    /// the words a question is made of ("why", "did", "the").
    static func searchWords(_ query: String) -> [String] {
        let folded = fold(query)
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !questionWords.contains($0) }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    static let itemRowLimit = 4
    static let pageRowLimit = 3
    static let keepWorkFor: TimeInterval = 60
    static let questionWords: Set<String> = [
        "what", "why", "how", "when", "where", "who", "which", "did", "does", "do", "is", "was", "are", "were",
        "the", "a", "an", "i", "my", "me", "to", "of", "in", "on", "for", "about", "with", "and", "or", "it",
        "that", "this", "can", "could", "should", "would", "we", "you", "your",
    ]
}
