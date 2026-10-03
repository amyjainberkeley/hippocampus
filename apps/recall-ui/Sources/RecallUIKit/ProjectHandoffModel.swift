import Combine
import Foundation

/// User-selected project context. Never guesses scope from recent global activity.
@MainActor
public final class ProjectHandoffModel: ObservableObject {
    @Published public private(set) var project: URL?
    @Published public private(set) var packet: String?
    @Published public private(set) var preparedAt: Date?
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    private var generation: UInt64 = 0
    private let exporter: @Sendable (URL) async throws -> String

    public init(exporter: @escaping @Sendable (URL) async throws -> String = { directory in
        try await ContextHandoffExporter.run(command: ContextHandoffCommand.makeProject(directory: directory))
    }) {
        self.exporter = exporter
    }

    public func selectProject(_ directory: URL) {
        guard directory.standardizedFileURL != project?.standardizedFileURL else { return }
        generation &+= 1
        project = directory
        packet = nil
        preparedAt = nil
        errorMessage = nil
        isLoading = false
    }

    public func refresh() async {
        guard let project, !isLoading else { return }
        generation &+= 1
        let request = generation
        isLoading = true
        packet = nil
        preparedAt = nil
        errorMessage = nil
        defer { if request == generation { isLoading = false } }
        do {
            let result = try await exporter(project)
            guard request == generation, !Task.isCancelled else { return }
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ContextHandoffError.emptyOutput
            }
            packet = result
            preparedAt = Date()
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            errorMessage = (error as? ContextHandoffError)?.errorDescription
                ?? "Context could not be prepared. Try again after opening Hippocampus."
        }
    }
}
