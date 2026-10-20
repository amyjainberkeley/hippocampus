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

    /// `folder` is where the sheet starts: a Working On item's folder, from
    /// its page or its row in the sidebar (SPEC 3.2). Nil starts it empty,
    /// as ⌘J does.
    public init(startingIn folder: URL? = nil,
                exporter: @escaping @Sendable (URL) async throws -> String = { directory in
                    try await ContextHandoffExporter.run(command: ContextHandoffCommand.makeProject(directory: directory))
                }) {
        self.exporter = exporter
        project = folder
    }

    /// The folder a code project's guess names ("~/dev/trailhead-shop", with
    /// `~` for home, or a full path), when it is a folder on this Mac; nil
    /// for anything else, so the sheet then starts empty and the person
    /// chooses.
    public nonisolated static func startingFolder(
        _ guess: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isFolder: (URL) -> Bool = ProjectHandoffModel.isFolder
    ) -> URL? {
        guard let guess = guess?.trimmingCharacters(in: .whitespacesAndNewlines), !guess.isEmpty else { return nil }
        let url: URL
        if guess == "~" {
            url = home
        } else if guess.hasPrefix("~/") {
            url = home.appendingPathComponent(String(guess.dropFirst(2)), isDirectory: true)
        } else if guess.hasPrefix("/") {
            url = URL(fileURLWithPath: guess, isDirectory: true)
        } else {
            return nil
        }
        let folder = url.standardizedFileURL
        return isFolder(folder) ? folder : nil
    }

    /// Whether `url` is a folder on this Mac.
    public nonisolated static func isFolder(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
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
