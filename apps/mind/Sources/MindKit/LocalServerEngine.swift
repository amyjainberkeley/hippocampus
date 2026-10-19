import Foundation
import IOKit.ps

/// A model served on this Mac over the OpenAI API: Ollama, LM Studio, or
/// anything else that speaks it at a local address.
///
/// - Only this Mac: the address must be 127.0.0.1, ::1 or localhost (sent to
///   127.0.0.1). Redirects are refused, and no cookie, cache or proxy is used.
/// - The model is chosen once, when the process starts, so the label the
///   ready line gives stays true. With none set, the first family in
///   `preferred` that the server lists is used, and never a model that runs
///   in a cloud.
/// - `unavailableReason()` never waits: it returns what was last seen and,
///   once that is 30 s old, asks the server again in the background.
/// - Prompts and temperatures are the Foundation engine's, over smaller
///   inputs (`LocalInputs`), because a server can cut a long prompt without
///   saying so. Replies are held to the limits the guided shapes set there.
/// - Work nobody asked for (claims, session notes, the day) waits for a power
///   cable (`on_battery`): a local model keeps gigabytes in memory and the
///   GPU busy. Ask's answers and suggestions always run.
public final class LocalServerEngine: MindEngine, @unchecked Sendable {
    /// Model families to use when none is set, best first.
    static let preferred = ["qwen3", "llama3.2", "llama3.1", "gemma3", "mistral", "phi"]

    /// The model's name as the server lists it.
    public let model: String
    /// The server's address, on this Mac; nil when none had a usable model.
    let base: URL?
    private let onACPower: @Sendable () -> Bool
    private let freshFor: TimeInterval
    /// The most any one request waits; tests make it short.
    private let longestWait: TimeInterval
    private let lock = NSLock()
    private var reason: String?
    private var checkedAt = Date()
    private var checking = false

    init(model: String, base: URL?, reason: String?,
         onACPower: @escaping @Sendable () -> Bool, freshFor: TimeInterval, longestWait: TimeInterval = .infinity) {
        self.model = model
        self.base = base
        self.reason = reason
        self.onACPower = onACPower
        self.freshFor = freshFor
        self.longestWait = longestWait
    }

    public var label: String { "local:\(model)" }

    public func unavailableReason() -> String? {
        lock.withLock {
            if !checking, base != nil, Date().timeIntervalSince(checkedAt) >= freshFor {
                checking = true
                Task.detached { await self.recheck() }
            }
            return reason
        }
    }

    // MARK: Finding a server and a model

    /// The first address in `settings` whose server lists a usable model, or
    /// an engine that says why there is none: `local_server_not_local`,
    /// `local_model_not_local` (a cloud model was named),
    /// `local_model_missing`, `local_model_unset` (nothing usable listed) or
    /// `local_server_unreachable`.
    public static func find(_ settings: EngineSettings,
                            onACPower: @escaping @Sendable () -> Bool = { PowerSource.onACPower() },
                            freshFor: TimeInterval = 30,
                            longestWait: TimeInterval = .infinity) async -> LocalServerEngine {
        var why = "local_server_unreachable"
        for address in settings.baseURLs {
            guard let base = local(address) else {
                why = worse(why, "local_server_not_local")
                continue
            }
            guard let names = await models(at: base) else { continue }
            switch choose(settings.model, from: names) {
            case .success(let model):
                return LocalServerEngine(model: model, base: base, reason: nil, onACPower: onACPower,
                                         freshFor: freshFor, longestWait: longestWait)
            case .failure(let refusal):
                why = worse(why, refusal.reason)
            }
        }
        return LocalServerEngine(model: settings.model, base: nil, reason: why, onACPower: onACPower,
                                 freshFor: freshFor, longestWait: longestWait)
    }

    struct Refusal: Error, Equatable { let reason: String }

    /// The model to use from the names a server lists: the one named, else
    /// the first preferred family, else the first that can chat.
    static func choose(_ named: String, from names: [String]) -> Result<String, Refusal> {
        let named = named.trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty {
            if isCloud(named) { return .failure(Refusal(reason: "local_model_not_local")) }
            guard let listed = names.first(where: { $0 == named || $0 == named + ":latest" }) else {
                return .failure(Refusal(reason: "local_model_missing"))
            }
            return .success(listed)
        }
        let usable = names.filter { !isCloud($0) && !isEmbedding($0) }
        for family in preferred {
            if let name = usable.first(where: { isOf(family, $0) }) { return .success(name) }
        }
        return usable.first.map { .success($0) } ?? .failure(Refusal(reason: "local_model_unset"))
    }

    /// Whether `name` is one of `family`'s models, written as Ollama writes
    /// it ("llama3.1:8b") or as LM Studio does ("meta-llama-3.1-8b-instruct",
    /// "google/gemma-3-4b"). The family starts a word: "dolphin" is not phi.
    static func isOf(_ family: String, _ name: String) -> Bool {
        // LM Studio puts a hyphen between a family and its version.
        let letters = Array(name.lowercased())
        var joined = ""
        for (index, letter) in letters.enumerated() {
            let beforeVersion = "-_ ".contains(letter) && index > 0 && index + 1 < letters.count
                && letters[index - 1].isLetter && letters[index + 1].isNumber
            if !beforeVersion { joined.append(letter) }
        }
        var from = joined.startIndex
        while let found = joined.range(of: family, range: from..<joined.endIndex) {
            if found.lowerBound == joined.startIndex || !joined[joined.index(before: found.lowerBound)].isLetter {
                return true
            }
            from = joined.index(after: found.lowerBound)
        }
        return false
    }

    /// Ollama names the models it runs on its own servers "…-cloud" or "…:cloud".
    static func isCloud(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.hasSuffix("-cloud") || name.hasSuffix(":cloud")
    }

    /// Models that turn text into numbers and cannot chat.
    static func isEmbedding(_ name: String) -> Bool {
        let name = name.lowercased()
        return ["embed", "minilm", "bge-", "rerank"].contains { name.contains($0) }
    }

    /// The more useful of two reasons to give.
    private static func worse(_ one: String, _ other: String) -> String {
        let order = ["local_server_unreachable", "local_model_unset", "local_model_missing",
                     "local_model_not_local", "local_server_not_local"]
        return (order.firstIndex(of: other) ?? 0) > (order.firstIndex(of: one) ?? 0) ? other : one
    }

    /// `address` when its host is this Mac, with localhost written as
    /// 127.0.0.1 and no trailing slash; else nil.
    static func local(_ address: String) -> URL? {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let host = parts.percentEncodedHost?.lowercased()
        else { return nil }
        switch host {
        case "127.0.0.1", "localhost": parts.percentEncodedHost = "127.0.0.1"
        case "[::1]", "::1": parts.percentEncodedHost = "[::1]"
        default: return nil
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
    }

    /// The names the server at `base` lists, or nil when it does not answer
    /// within 2 s.
    static func models(at base: URL) async -> [String]? {
        var request = URLRequest(url: base.appendingPathComponent("models"), timeoutInterval: 2)
        request.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [Any]
        else { return nil }
        return list.compactMap { ($0 as? [String: Any])?["id"] as? String }
    }

    private func recheck() async {
        var seen: String?
        if let base {
            if let names = await Self.models(at: base) {
                seen = names.contains(model) ? nil : "local_model_missing"
            } else {
                seen = "local_server_unreachable"
            }
        }
        lock.withLock {
            reason = seen
            checkedAt = Date()
            checking = false
        }
    }

    /// What a request just learned; the next `unavailableReason()` asks again.
    private func saw(_ seen: String) {
        lock.withLock {
            reason = seen
            checkedAt = .distantPast
        }
    }

    /// No cookies, cache, stored credentials or proxy, and no redirects.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
            kCFNetworkProxiesProxyAutoConfigEnable as String: false,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String: false,
        ]
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    // MARK: Tasks

    public func propose(_ input: ProposeInput) async throws -> ProposeOutput {
        try waitForPower()
        let input = LocalInputs.propose(input)
        let reply = try await chat("propose", Schemas.propositions, userName: input.userName, prompt: Prompts.propose(input),
                                   temperature: 0.3, maxTokens: 800, timeout: 45)
        return ProposeOutput(propositions: Array(Self.objects(reply["propositions"]).compactMap(Self.draft).prefix(3)))
    }

    public func relate(_ input: RelateInput) async throws -> RelateOutput {
        try waitForPower()
        let input = LocalInputs.relate(input)
        let reply = try await chat("relate", Schemas.relations, userName: "", prompt: Prompts.relate(input),
                                   temperature: 0, maxTokens: 400, timeout: 45)
        let known = Set(input.candidates.map(\.id))
        return RelateOutput(relations: Self.objects(reply["relations"]).compactMap { item in
            guard let id = Self.integer(item["id"]), known.contains(id) else { return nil }
            return Relation(id: id, relation: RelationKind(rawValue: Self.string(item["relation"])?.lowercased() ?? "") ?? .unrelated)
        })
    }

    public func revise(_ input: ReviseInput) async throws -> PropositionDraft {
        try waitForPower()
        let input = LocalInputs.revise(input)
        let reply = try await chat("revise", Schemas.proposition, userName: input.userName, prompt: Prompts.revise(input),
                                   temperature: 0.3, maxTokens: 400, timeout: 45)
        guard let draft = Self.draft(reply) else { throw MindError.failed }
        return draft
    }

    public func episode(_ input: EpisodeInput) async throws -> EpisodeOutput {
        try waitForPower()
        let input = LocalInputs.episode(input)
        let reply = try await chat("episode", Schemas.episode, userName: input.userName, prompt: Prompts.episode(input),
                                   temperature: 0.3, maxTokens: 400, timeout: 45)
        guard let title = Self.string(reply["title"]), let surface = Self.string(reply["surface"]) else { throw MindError.failed }
        return EpisodeOutput(title: title, surface: surface, beneath: Self.string(reply["beneath"]) ?? "Nothing notable.")
    }

    /// As the Foundation engine does it: the account is asked for up to three
    /// times, and an account that states a length is asked for again
    /// (`DayReply`). All of it fits in 80 s, inside the agent's 90 s.
    public func day(_ input: DayInput) async throws -> DayOutput {
        try waitForPower()
        let input = LocalInputs.day(input)
        let prompt = Prompts.day(input)
        let deadline = Date().addingTimeInterval(80)
        for _ in 1...3 {
            let left = deadline.timeIntervalSinceNow
            guard left > 5 else { break }
            let reply: [String: Any]
            do {
                reply = try await chat("day", Schemas.day, userName: input.userName, prompt: prompt,
                                       temperature: 0.4, maxTokens: 300, timeout: min(45, left))
            } catch MindError.failed {
                continue
            }
            guard let headline = Self.string(reply["headline"]), let narrative = Self.string(reply["narrative"]),
                  let account = DayReply.account(headline: headline, narrative: narrative, shown: prompt)
            else { continue }
            // Insights are optional, so the account stands without them.
            var insights: [String] = []
            let rest = deadline.timeIntervalSinceNow
            if rest > 5, let facts = try? await chat("day_facts", Schemas.dayFacts, userName: input.userName,
                                                     prompt: Prompts.dayFacts(input), temperature: 0.3,
                                                     maxTokens: 300, timeout: min(25, rest)) {
                insights = Array(((facts["insights"] as? [Any]) ?? []).compactMap(Self.string).prefix(3))
            }
            return DayOutput(headline: account.headline, narrative: account.narrative,
                             insights: DayReply.insights(insights, facts: Prompts.dayFactLines(input.facts)))
        }
        throw MindError.failed
    }

    public func answer(_ input: AnswerInput) async throws -> AnswerOutput {
        let input = LocalInputs.answer(input)
        let reply = try await chat("answer", Schemas.answer, userName: input.userName, prompt: Prompts.answer(input),
                                   temperature: 0.2, maxTokens: 500, timeout: 45)
        guard let answer = Self.string(reply["answer"]) else { throw MindError.failed }
        let valid = Set(input.memories.map(\.n))
        var cited = Set<Int>()
        let sources = ((reply["sources"] as? [Any]) ?? []).compactMap(Self.integer).filter { valid.contains($0) && cited.insert($0).inserted }
        return AnswerOutput(answer: answer, sources: sources)
    }

    public func suggest(_ input: SuggestInput) async throws -> SuggestOutput {
        let input = LocalInputs.suggest(input)
        let reply = try await chat("suggest", Schemas.suggestions, userName: input.userName, prompt: Prompts.suggest(input),
                                   temperature: 0.3, maxTokens: 500, timeout: 25)
        return SuggestOutput(suggestions: Array(Self.objects(reply["suggestions"]).compactMap { item -> SuggestionItem? in
            guard let title = Self.string(item["title"]), let usefulness = Self.integer(item["usefulness"]) else { return nil }
            return SuggestionItem(title: title, why: Self.string(item["why"]) ?? "", usefulness: Self.scale(usefulness))
        }.prefix(4)))
    }

    public func caption(_ input: CaptionInput) async throws -> CaptionOutput {
        try waitForPower()
        let input = CaptionInputs.bounded(input, textCharacters: 400, moments: 6)
        guard !input.moments.isEmpty else { return CaptionOutput(captions: []) }
        let reply = try await chat("caption", Schemas.captions, userName: "", prompt: Prompts.caption(input),
                                   temperature: 0.2, maxTokens: 300, timeout: 45)
        let lines = Self.objects(reply["captions"]).compactMap { item -> CaptionLine? in
            guard let n = Self.integer(item["n"]), let caption = Self.string(item["caption"]) else { return nil }
            return CaptionLine(n: n, caption: caption)
        }
        return CaptionInputs.answered(lines, for: input)
    }

    private func waitForPower() throws {
        guard onACPower() else { throw MindError.onBattery }
    }

    // MARK: Asking the server

    /// One task: `POST {base}/chat/completions`, with the reply's JSON schema
    /// both in the prompt (as Foundation Models does) and as the response
    /// format. A server that refuses the format (HTTP 400) is asked once
    /// more without it.
    private func chat(_ name: String, _ schema: String, userName: String, prompt: String,
                      temperature: Double, maxTokens: Int, timeout: TimeInterval) async throws -> [String: Any] {
        guard let base else { throw MindError.unavailable }
        let timeout = min(timeout, longestWait)
        let shaped = prompt + "\n\nReply in JSON that follows this schema:\n" + schema
        func messages(_ user: String) -> [[String: String]] {
            // Qwen3 thinks aloud first unless told not to, which the time
            // allowed cannot spare.
            let user = model.lowercased().contains("qwen3") ? user + "\n/no_think" : user
            return [["role": "system", "content": Prompts.instructions(userName: userName)], ["role": "user", "content": user]]
        }
        let started = Date()
        do {
            return try await complete(base, messages(shaped), format: (name, schema), temperature: temperature,
                                      maxTokens: maxTokens, timeout: timeout)
        } catch is FormatRefused {
            let left = timeout - Date().timeIntervalSince(started)
            guard left > 1 else { throw MindError.failed }
            return try await complete(base, messages(shaped + "\nReply with JSON only."), format: nil,
                                      temperature: temperature, maxTokens: maxTokens, timeout: left)
        }
    }

    private struct FormatRefused: Error {}

    /// What a request with no reply means. Nothing listening: `unavailable`
    /// until the server is seen again. Too slow (a model loading, a large
    /// model) or cut off: `failed`, this once. Ask stops offering answers
    /// for a while after `unavailable`, so a slow reply must not say it.
    static func failure(_ error: Error) -> MindError {
        switch (error as? URLError)?.code {
        case .cannotConnectToHost?, .cannotFindHost?, .dnsLookupFailed?, .notConnectedToInternet?: .unavailable
        default: .failed
        }
    }

    private func complete(_ base: URL, _ messages: [[String: String]], format: (name: String, schema: String)?,
                          temperature: Double, maxTokens: Int, timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent("chat").appendingPathComponent("completions"),
                                 timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false, "temperature": temperature, "max_tokens": maxTokens, "messages": messages,
        ] as [String: Any])
        if let format {
            // Spliced in as text, so the properties keep their order.
            body.removeLast()
            body.append(Data(#","response_format":{"type":"json_schema","json_schema":{"name":"\#(format.name)","strict":true,"schema":\#(format.schema)}}}"#.utf8))
        }
        request.httpBody = body
        let data: Data
        let status: Int
        do {
            let (reply, response) = try await Self.session.data(for: request)
            data = reply
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            let failure = Self.failure(error)
            if failure == .unavailable { saw("local_server_unreachable") }
            throw failure
        }
        guard status == 200 else {
            let said = String(decoding: data.prefix(4_096), as: UTF8.self).lowercased()
            if [400, 413].contains(status), ["context", "too long", "too many tokens"].contains(where: said.contains) {
                throw MindError.contextTooLong
            }
            if [400, 422].contains(status), format != nil { throw FormatRefused() }
            if status == 404, said.contains("model") {
                saw("local_model_missing")
                throw MindError.unavailable
            }
            throw MindError.failed
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [Any])?.first as? [String: Any],
              let content = (choice["message"] as? [String: Any])?["content"] as? String,
              let reply = Self.jsonObject(in: content)
        else { throw MindError.failed }
        return reply
    }

    // MARK: Reading replies

    /// The JSON object in a reply's text: after any thinking, inside any code
    /// fence, from the first "{" to the last "}".
    static func jsonObject(in content: String) -> [String: Any]? {
        var text = Substring(content)
        if let thought = text.range(of: "</think>", options: .backwards) { text = text[thought.upperBound...] }
        if let fence = text.range(of: "```") {
            var inside = text[fence.upperBound...]
            if let newline = inside.firstIndex(of: "\n") { inside = inside[inside.index(after: newline)...] }
            if let close = inside.range(of: "```") { inside = inside[..<close.lowerBound] }
            text = inside
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
    }

    static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// A whole number, from a number or from digits in a string.
    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let double = number.doubleValue
            guard double.isFinite else { return nil }
            return Int(min(1e9, max(-1e9, double)).rounded())
        }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    static func objects(_ value: Any?) -> [[String: Any]] {
        ((value as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
    }

    /// Scores are 1 to 10.
    static func scale(_ value: Int) -> Int { min(10, max(1, value)) }

    /// A proposition with its scores in range and a known kind (any other
    /// becomes `state`), or nil without a sentence or scores.
    static func draft(_ item: [String: Any]) -> PropositionDraft? {
        guard let text = string(item["text"]), let confidence = integer(item["confidence"]),
              let decay = integer(item["decay"])
        else { return nil }
        let kind = string(item["kind"])?.lowercased() ?? ""
        return PropositionDraft(text: text, reasoning: string(item["reasoning"]) ?? "",
                                kind: Schemas.kinds.contains(kind) ? kind : "state",
                                confidence: scale(confidence), decay: scale(decay))
    }
}

/// Refuses every redirect, so the reply to one is the redirect itself.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Inputs cut down for a model server. Ollama's OpenAI endpoint cannot be
/// told the window size and cuts a long prompt without saying so, so each
/// prompt stays near 1,600 tokens, about half what Apple's model is sent.
enum LocalInputs {
    static func propose(_ input: ProposeInput) -> ProposeInput {
        var input = input
        input.observation = Prompts.clip(input.observation, 3_000)
        input.known = Array(input.known.prefix(6))
        return input
    }

    static func relate(_ input: RelateInput) -> RelateInput {
        var input = input
        input.candidates = Array(input.candidates.prefix(6))
        return input
    }

    static func revise(_ input: ReviseInput) -> ReviseInput {
        var input = input
        input.old = Array(input.old.prefix(3))
        return input
    }

    static func episode(_ input: EpisodeInput) -> EpisodeInput {
        var input = input
        input.observation = Prompts.clip(input.observation, 3_000)
        return input
    }

    static func day(_ input: DayInput) -> DayInput {
        var input = input
        input.episodes = Array(input.episodes.prefix(12))
        input.facts = Prompts.clip(input.facts, 1_800)
        return input
    }

    static func answer(_ input: AnswerInput) -> AnswerInput {
        var input = input
        input.question = Prompts.clip(input.question, 400)
        input.now = input.now.map { Prompts.clip($0, 900) }
        input.memories = input.memories.prefix(6).map { memory in
            var memory = memory
            memory.text = Prompts.clip(memory.text, 320)
            return memory
        }
        input.propositions = Array(input.propositions.prefix(4))
        return input
    }

    static func suggest(_ input: SuggestInput) -> SuggestInput {
        var input = input
        input.now = Prompts.clip(input.now, 800)
        input.recent = Array(input.recent.prefix(6))
        input.propositions = Array(input.propositions.prefix(4))
        return input
    }
}

/// Whether this Mac runs from a power cable.
public enum PowerSource {
    /// False only on battery power: true on a cable, and on a Mac with no
    /// battery.
    public static func onACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return true }
        return (type as String) != kIOPSBatteryPowerValue
    }
}
