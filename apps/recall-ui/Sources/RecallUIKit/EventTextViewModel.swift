import Combine
import Foundation

/// Holds only the selected event's reading; canceled or superseded reads never publish.
@MainActor
public final class EventTextViewModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case loading
        case loaded(EventReading)
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

    public func text(for hit: Hit) -> EventReading? {
        guard case let .loaded(reading) = state(for: hit), reading.matches(hit) else { return nil }
        return reading
    }

    /// What is shown, and what "Copy Text" copies: the reading, then the rest
    /// of the window when "Also in this window" is open; the list's excerpt
    /// until the reading is there. Never a header (RULINGS T12, T14, T17).
    public func copyText(for hit: Hit, includingRest: Bool = false) -> String {
        text(for: hit)?.text(includingRest: includingRest) ?? ReadableText.guarded(hit.ocrTextSnippet)
    }

    /// "Also in this window" opens by itself when the search's words are only
    /// there (RULINGS T12).
    public func opensRest(for hit: Hit) -> Bool {
        text(for: hit)?.matchIn == .rest
    }

    /// Read the selected moment. With the search's text, the reading says
    /// whether its words are only in the rest of the window.
    public func load(hit: Hit, reader: BrainReader?, query: String? = nil) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        requestID = request
        selection = hit
        currentState = .loading
        guard let reader else {
            currentState = .unavailable
            return
        }
        // Blank search text is no search.
        let query = query.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        do {
            let value = try await reader.eventReading(eventId: hit.id, query: query)
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
