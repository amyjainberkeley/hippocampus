import RecallUIKit
import SwiftUI

/// Conversations (SPEC-DELTA 1): chats, email and AI chats read, listed by
/// conversation name only. A lens over History: History's own rows and
/// detail, filtered to conversations, with nothing History doesn't have.
///
/// A seam for now: an empty page. It is built as History's lens.
struct ConversationsPlace: View {
    let reader: BrainReader
    let open: (RecallRoute) -> Void

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
