import Foundation

/// What an Ask {Tool} button hands to a person's AI (SPEC 5.3.1, 5.3.3):
/// the moments they picked, a session, a Working On item or a question.
/// It names what to send by ids and times only; the one builder
/// (`mci-agent send-card`) reads the rest from memory just before anything
/// opens, so a moment forgotten since the click is left out.
public enum AskAISource: Equatable, Hashable, Sendable {
    /// Moments, newest first: History's detail or selection, a web page, a search.
    case moments([UInt64])
    /// A session on Today: its title and its own time, in microseconds.
    case session(title: String, range: ClosedRange<Int64>)
    /// A Working On item, by its id.
    case item(String)
    /// A question, with the moments its answer cited or its top matches.
    case question(String, moments: [UInt64])

    /// The moments it names directly, newest first: none for a session or an
    /// item, which the builder reads by time or by id.
    public var momentIds: [UInt64] {
        switch self {
        case let .moments(ids), let .question(_, ids): ids
        case .session, .item: []
        }
    }
}
