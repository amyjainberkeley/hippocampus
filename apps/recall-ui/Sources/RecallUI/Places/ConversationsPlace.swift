import RecallUIKit
import SwiftUI

/// Conversations (SPEC-DELTA 1): chats, email and AI chats read, with
/// All, Chat, Email and AI chips. A lens over History: History’s own rows
/// and detail, filtered to conversations, with nothing History doesn’t have.
struct ConversationsPlace: View {
    let reader: BrainReader
    let open: (RecallRoute) -> Void
    /// Working On's read, for "Part of …" under a moment's header.
    var work: (any WorkReader)? = nil
    var calendar: Calendar = .current
    var now: @Sendable () -> Date = { Date() }

    var body: some View {
        LibraryLensPlace(lens: .conversations, reader: reader, work: work, open: open, calendar: calendar, now: now)
    }
}
