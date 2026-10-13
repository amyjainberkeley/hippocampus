import Foundation
import MindKit

// `hippocampus-mind --serve` over an engine that takes a minute to answer,
// so ServeLoopTests can close stdin while a request is being answered. Each
// request writes "answering" to stderr as it starts.

struct SlowEngine: MindEngine {
    func unavailableReason() -> String? { nil }
    func propose(_ input: ProposeInput) async throws -> ProposeOutput { try await slowly() }
    func relate(_ input: RelateInput) async throws -> RelateOutput { try await slowly() }
    func revise(_ input: ReviseInput) async throws -> PropositionDraft { try await slowly() }
    func episode(_ input: EpisodeInput) async throws -> EpisodeOutput { try await slowly() }
    func day(_ input: DayInput) async throws -> DayOutput { try await slowly() }
    func answer(_ input: AnswerInput) async throws -> AnswerOutput { try await slowly() }
    func suggest(_ input: SuggestInput) async throws -> SuggestOutput { try await slowly() }

    private func slowly<Output>() async throws -> Output {
        FileHandle.standardError.write(Data("answering\n".utf8))
        try await Task.sleep(for: .seconds(60))
        throw MindError.failed
    }
}

await MindServer(engine: SlowEngine()).serve()
