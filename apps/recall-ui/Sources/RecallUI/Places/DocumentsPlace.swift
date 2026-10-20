import RecallUIKit
import SwiftUI

/// Documents (SPEC-DELTA 1): docs, notes, sheets and designs worked on. A
/// lens over History: History’s own rows and detail, filtered to documents,
/// with nothing History doesn’t have.
struct DocumentsPlace: View {
    let reader: BrainReader
    let open: (RecallRoute) -> Void
    /// Working On's read, for "Part of …" under a moment's header.
    var work: (any WorkReader)? = nil
    var calendar: Calendar = .current
    var now: @Sendable () -> Date = { Date() }

    var body: some View {
        LibraryLensPlace(lens: .documents, reader: reader, work: work, open: open, calendar: calendar, now: now)
    }
}
