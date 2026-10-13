import Foundation

// One JSON object per line in each direction. Lines end at a newline (0x0A)
// only.
//
// Request:  {"id": 7, "task": "propose", "input": {...}}
// Reply:    {"id": 7, "ok": true, "output": {...}}
//           {"id": 7, "ok": false, "error": "context_too_long"}
// On start: {"ready": true, "available": true}
//           {"ready": true, "available": false, "reason": "apple_intelligence_off"}

/// The tasks the mind performs.
public enum MindTask: String, Codable, Sendable, CaseIterable {
    case propose, relate, revise, episode, day, answer, suggest
}

/// Error codes a caller can act on.
public enum MindError: String, Error, Codable, Sendable {
    /// The model is not available on this Mac (or not yet ready).
    case unavailable
    /// The input did not fit; send less.
    case contextTooLong = "context_too_long"
    /// The model declined (safety guardrail).
    case refused
    /// Malformed request.
    case badRequest = "bad_request"
    /// Anything else.
    case failed
}

// MARK: Inputs

/// Observations of a stretch of the user's work.
public struct ProposeInput: Codable, Sendable, Equatable {
    public var userName: String
    public var observation: String
    /// Propositions already held, so the model refines instead of repeating.
    public var known: [String]
    public init(userName: String, observation: String, known: [String]) {
        self.userName = userName; self.observation = observation; self.known = known
    }
    enum CodingKeys: String, CodingKey { case userName = "user_name", observation, known }
}

public struct Candidate: Codable, Sendable, Equatable {
    public var id: Int
    public var text: String
    public init(id: Int, text: String) { self.id = id; self.text = text }
}

public struct RelateInput: Codable, Sendable, Equatable {
    public var proposition: String
    public var candidates: [Candidate]
    public init(proposition: String, candidates: [Candidate]) {
        self.proposition = proposition; self.candidates = candidates
    }
}

public struct PropositionDraft: Codable, Sendable, Equatable {
    public var text: String
    public var reasoning: String
    public var kind: String
    /// 1...10
    public var confidence: Int
    /// 1...10
    public var decay: Int
    public init(text: String, reasoning: String, kind: String, confidence: Int, decay: Int) {
        self.text = text; self.reasoning = reasoning; self.kind = kind
        self.confidence = confidence; self.decay = decay
    }
}

public struct ReviseInput: Codable, Sendable, Equatable {
    public var userName: String
    public var new: PropositionDraft
    public var old: [PropositionDraft]
    public init(userName: String, new: PropositionDraft, old: [PropositionDraft]) {
        self.userName = userName; self.new = new; self.old = old
    }
    enum CodingKeys: String, CodingKey { case userName = "user_name", new, old }
}

public struct EpisodeInput: Codable, Sendable, Equatable {
    public var userName: String
    public var observation: String
    public init(userName: String, observation: String) {
        self.userName = userName; self.observation = observation
    }
    enum CodingKeys: String, CodingKey { case userName = "user_name", observation }
}

public struct DayInput: Codable, Sendable, Equatable {
    public var userName: String
    /// The measured breakdown, written out.
    public var facts: String
    /// Episode titles and summaries, in order.
    public var episodes: [String]
    /// What the user model holds.
    public var propositions: [String]
    public init(userName: String, facts: String, episodes: [String], propositions: [String]) {
        self.userName = userName; self.facts = facts; self.episodes = episodes; self.propositions = propositions
    }
    enum CodingKeys: String, CodingKey { case userName = "user_name", facts, episodes, propositions }
}

public struct Memory: Codable, Sendable, Equatable {
    /// Number the answer cites.
    public var n: Int
    public var when: String
    public var source: String
    public var text: String
    public init(n: Int, when: String, source: String, text: String) {
        self.n = n; self.when = when; self.source = source; self.text = text
    }
}

public struct AnswerInput: Codable, Sendable, Equatable {
    public var userName: String
    public var question: String
    /// What is on screen now, if known.
    public var now: String?
    public var memories: [Memory]
    public var propositions: [String]
    public var today: String
    public init(userName: String, question: String, now: String?, memories: [Memory], propositions: [String], today: String) {
        self.userName = userName; self.question = question; self.now = now
        self.memories = memories; self.propositions = propositions; self.today = today
    }
    enum CodingKeys: String, CodingKey { case userName = "user_name", question, now, memories, propositions, today }
}

public struct SuggestInput: Codable, Sendable, Equatable {
    public var userName: String
    public var now: String
    public var recent: [String]
    public var propositions: [String]
    public init(userName: String, now: String, recent: [String], propositions: [String]) {
        self.userName = userName; self.now = now; self.recent = recent; self.propositions = propositions
    }
    enum CodingKeys: String, CodingKey { case userName = "user_name", now, recent, propositions }
}

// MARK: Outputs

public struct ProposeOutput: Codable, Sendable, Equatable {
    public var propositions: [PropositionDraft]
    public init(propositions: [PropositionDraft]) { self.propositions = propositions }
}

public enum RelationKind: String, Codable, Sendable { case identical, similar, unrelated }

public struct Relation: Codable, Sendable, Equatable {
    public var id: Int
    public var relation: RelationKind
    public init(id: Int, relation: RelationKind) { self.id = id; self.relation = relation }
}

public struct RelateOutput: Codable, Sendable, Equatable {
    public var relations: [Relation]
    public init(relations: [Relation]) { self.relations = relations }
}

public struct EpisodeOutput: Codable, Sendable, Equatable {
    public var title: String
    public var surface: String
    public var beneath: String
    public init(title: String, surface: String, beneath: String) {
        self.title = title; self.surface = surface; self.beneath = beneath
    }
}

public struct DayOutput: Codable, Sendable, Equatable {
    public var headline: String
    public var narrative: String
    /// At most three.
    public var insights: [String]
    /// Always empty: the day's account gives no advice. The key stays so the
    /// agent decodes the reply unchanged.
    public private(set) var suggestion = ""
    public init(headline: String, narrative: String, insights: [String]) {
        self.headline = headline; self.narrative = narrative; self.insights = insights
    }
}

public struct AnswerOutput: Codable, Sendable, Equatable {
    public var answer: String
    public var sources: [Int]
    public init(answer: String, sources: [Int]) { self.answer = answer; self.sources = sources }
}

public struct SuggestionItem: Codable, Sendable, Equatable {
    public var title: String
    public var why: String
    /// 1...10
    public var usefulness: Int
    public init(title: String, why: String, usefulness: Int) {
        self.title = title; self.why = why; self.usefulness = usefulness
    }
}

public struct SuggestOutput: Codable, Sendable, Equatable {
    public var suggestions: [SuggestionItem]
    public init(suggestions: [SuggestionItem]) { self.suggestions = suggestions }
}

// MARK: Engine seam

/// What answers the tasks. The real engine is Foundation Models; tests use a fake.
public protocol MindEngine: Sendable {
    /// `nil` when available, else a short reason code.
    func unavailableReason() -> String?
    func propose(_ input: ProposeInput) async throws -> ProposeOutput
    func relate(_ input: RelateInput) async throws -> RelateOutput
    func revise(_ input: ReviseInput) async throws -> PropositionDraft
    func episode(_ input: EpisodeInput) async throws -> EpisodeOutput
    func day(_ input: DayInput) async throws -> DayOutput
    func answer(_ input: AnswerInput) async throws -> AnswerOutput
    func suggest(_ input: SuggestInput) async throws -> SuggestOutput
}

// MARK: Serving

/// Turns one request line into one reply line. Never throws: every failure
/// becomes an `ok: false` reply with a code.
public struct MindServer: Sendable {
    let engine: any MindEngine

    public init(engine: any MindEngine) { self.engine = engine }

    public func readyLine() -> Data {
        var object: [String: Any] = ["ready": true]
        if let reason = engine.unavailableReason() {
            object["available"] = false
            object["reason"] = reason
        } else {
            object["available"] = true
        }
        return line(object)
    }

    public func handle(_ requestLine: Data) async -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: requestLine) as? [String: Any],
              let id = object["id"] as? Int,
              let taskName = object["task"] as? String,
              let task = MindTask(rawValue: taskName),
              let inputObject = object["input"],
              let input = try? JSONSerialization.data(withJSONObject: inputObject)
        else {
            let id = (try? JSONSerialization.jsonObject(with: requestLine) as? [String: Any])?["id"] as? Int ?? -1
            return failure(id: id, .badRequest)
        }
        if engine.unavailableReason() != nil { return failure(id: id, .unavailable) }
        do {
            let output: Data
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            switch task {
            case .propose: output = try encoder.encode(try await engine.propose(decoder.decode(ProposeInput.self, from: input)))
            case .relate: output = try encoder.encode(try await engine.relate(decoder.decode(RelateInput.self, from: input)))
            case .revise: output = try encoder.encode(try await engine.revise(decoder.decode(ReviseInput.self, from: input)))
            case .episode: output = try encoder.encode(try await engine.episode(decoder.decode(EpisodeInput.self, from: input)))
            case .day: output = try encoder.encode(try await engine.day(decoder.decode(DayInput.self, from: input)))
            case .answer: output = try encoder.encode(try await engine.answer(decoder.decode(AnswerInput.self, from: input)))
            case .suggest: output = try encoder.encode(try await engine.suggest(decoder.decode(SuggestInput.self, from: input)))
            }
            let outputObject = try JSONSerialization.jsonObject(with: output)
            return line(["id": id, "ok": true, "output": outputObject])
        } catch let error as MindError {
            return failure(id: id, error)
        } catch is DecodingError {
            return failure(id: id, .badRequest)
        } catch {
            return failure(id: id, .failed)
        }
    }

    private func failure(id: Int, _ error: MindError) -> Data {
        line(["id": id, "ok": false, "error": error.rawValue])
    }

    private func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }
}

extension MindServer {
    /// `hippocampus-mind --serve`: writes the ready line, then answers each
    /// request line on stdin with one reply line on stdout, in order. Exits
    /// as soon as stdin ends, even mid-request: whoever asked has gone, and
    /// an answer can take a minute.
    public func serve() async -> Never {
        FileHandle.standardOutput.write(readyLine())
        // stdin is read in a task of its own, so its end is seen while a
        // request is being answered.
        let (requests, received) = AsyncStream.makeStream(of: Data.self)
        Task.detached {
            var line = Data()
            do {
                // Only a newline ends a request. `lines` also breaks at
                // U+2028 and U+0085, which JSON strings carry unescaped.
                for try await byte in FileHandle.standardInput.bytes {
                    if byte != 0x0A {
                        line.append(byte)
                    } else if !line.isEmpty {
                        received.yield(line)
                        line = Data()
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("hippocampus-mind: input closed with an error\n".utf8))
            }
            exit(0)
        }
        for await request in requests {
            FileHandle.standardOutput.write(await handle(request))
        }
        exit(0)
    }
}
