import Foundation

/// Picks who answers, once, when the process starts.
public enum EngineChoice {
    /// `auto` uses Apple Intelligence when it is on, else a model server on
    /// this Mac with a usable model. When neither can answer, the reason says
    /// what would help: `model_not_ready` while Apple Intelligence gets
    /// ready, `local_server_not_local` for an address that is not this Mac,
    /// else `needs_apple_intelligence_or_local_model`. `apple` and `local`
    /// give their own engine's reasons, and `needs_macos_26` for Apple's
    /// model before macOS 26.
    public static func engine(
        for settings: EngineSettings,
        apple: (any MindEngine)? = appleEngine(),
        local: (EngineSettings) async -> LocalServerEngine = { await LocalServerEngine.find($0) }
    ) async -> any MindEngine {
        switch settings.engine {
        case .apple:
            return apple ?? UnavailableEngine(reason: "needs_macos_26")
        case .local:
            return await local(settings)
        case .auto:
            if let apple, apple.unavailableReason() == nil { return apple }
            let server = await local(settings)
            if server.unavailableReason() == nil { return server }
            if let apple, apple.unavailableReason() == "model_not_ready" { return apple }
            if server.unavailableReason() == "local_server_not_local" { return server }
            return UnavailableEngine(reason: "needs_apple_intelligence_or_local_model")
        }
    }

    /// Apple's model, available or not, on a Mac whose macOS has it.
    public static func appleEngine() -> (any MindEngine)? {
        #if canImport(FoundationModels) && !MIND_NO_FOUNDATION_MODELS
        if #available(macOS 26.0, *) { return FoundationEngine() }
        #endif
        return nil
    }
}

/// Answers nothing, and says why.
public struct UnavailableEngine: MindEngine {
    public let reason: String
    public init(reason: String) { self.reason = reason }

    public var label: String { "none" }
    public func unavailableReason() -> String? { reason }
    public func propose(_ input: ProposeInput) async throws -> ProposeOutput { throw MindError.unavailable }
    public func relate(_ input: RelateInput) async throws -> RelateOutput { throw MindError.unavailable }
    public func revise(_ input: ReviseInput) async throws -> PropositionDraft { throw MindError.unavailable }
    public func episode(_ input: EpisodeInput) async throws -> EpisodeOutput { throw MindError.unavailable }
    public func day(_ input: DayInput) async throws -> DayOutput { throw MindError.unavailable }
    public func answer(_ input: AnswerInput) async throws -> AnswerOutput { throw MindError.unavailable }
    public func suggest(_ input: SuggestInput) async throws -> SuggestOutput { throw MindError.unavailable }
    public func caption(_ input: CaptionInput) async throws -> CaptionOutput { throw MindError.unavailable }
}
