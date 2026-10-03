import Combine
import Foundation

@MainActor
public final class ScreenshotRereadViewModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case reading
        case finished(ScreenshotRereadOutcome)
    }
    @Published private var currentState: State = .idle
    private var selection: Hit?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private let service: any ScreenshotRereading

    public init(service: any ScreenshotRereading = LocalScreenshotRereader()) { self.service = service }

    public func state(for hit: Hit) -> State { selection == hit ? currentState : .idle }

    @discardableResult
    public func start(hit: Hit, reader: any BrainReader) -> Task<Void, Never> {
        clear()
        selection = hit
        currentState = .reading
        let request = generation
        let service = service
        let run = Task { [weak self] in
            guard let self else { return }
            defer { if generation == request { task = nil } }
            guard let url = hit.thumbnailURL, await Self.stillExists(hit, reader: reader) else {
                if generation == request { currentState = .finished(.unavailable) }
                return
            }
            guard !Task.isCancelled, generation == request else { return }
            let outcome = await service.read(url: url)
            guard !Task.isCancelled, generation == request else { return }
            let exists = await Self.stillExists(hit, reader: reader)
            guard !Task.isCancelled, generation == request else { return }
            currentState = .finished(exists ? outcome : .unavailable)
        }
        task = run
        return run
    }

    public func copyText(for hit: Hit, reader: any BrainReader) async -> String? {
        guard case let .finished(.text(text, _)) = state(for: hit) else { return nil }
        let request = generation
        let exists = await Self.stillExists(hit, reader: reader)
        guard !Task.isCancelled, generation == request else { return nil }
        guard exists else { clear(); return nil }
        return text
    }

    public func clear() {
        generation = UUID()
        task?.cancel()
        task = nil
        selection = nil
        currentState = .idle
    }

    private static func stillExists(_ expected: Hit, reader: any BrainReader) async -> Bool {
        guard let current = try? await reader.fetchEventsByIds([expected.id]).first(where: { $0.id == expected.id }) else { return false }
        return current.tsUs == expected.tsUs && current.appBundleId == expected.appBundleId
            && current.windowTitle == expected.windowTitle && current.url == expected.url
            && current.thumbnailPath == expected.thumbnailPath && current.sourceKind == expected.sourceKind
    }
}
