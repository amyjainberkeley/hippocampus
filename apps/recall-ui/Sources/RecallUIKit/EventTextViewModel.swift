import Combine
import Foundation

/// Holds only the selected event's text; canceled or superseded reads never publish.
@MainActor
public final class EventTextViewModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case loading
        case loaded(EventText)
        case unavailable
        case failed
    }

    @Published private var selection: Hit?
    @Published private var currentState: State = .idle
    private var requestID = UUID()

    public init() {}

    public func state(for hit: Hit) -> State {
        selection == hit ? currentState : .idle
    }

    public func text(for hit: Hit) -> EventText? {
        guard case let .loaded(text) = state(for: hit), text.matches(hit) else { return nil }
        return text
    }

    public func copyText(for hit: Hit) -> String {
        text(for: hit)?.text ?? Formatters.stripContextHeader(hit.ocrTextSnippet)
    }

    public func copyTitle(for hit: Hit) -> String {
        guard let value = text(for: hit) else { return "Copy Snippet" }
        return value.isTruncated ? "Copy Shown Text" : "Copy Full Text"
    }

    public func load(hit: Hit, reader: BrainReader?) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        requestID = request
        selection = hit
        currentState = .loading
        guard let reader else {
            currentState = .unavailable
            return
        }
        do {
            let value = try await reader.eventText(eventId: hit.id)
            guard requestID == request else { return }
            guard !Task.isCancelled else {
                currentState = .idle
                return
            }
            if let value {
                currentState = value.matches(hit) ? .loaded(value) : .unavailable
            } else {
                currentState = .unavailable
            }
        } catch {
            guard requestID == request else { return }
            currentState = Task.isCancelled || error is CancellationError ? .idle : .failed
        }
    }

    public func clear() {
        requestID = UUID()
        currentState = .idle
        selection = nil
    }
}
