import RecallUIKit
import SwiftUI

/// Code (SPEC-DELTA 1): projects worked on in an editor or a terminal. A
/// lens over History: History’s own rows and detail, filtered to code,
/// with nothing History doesn’t have.
struct CodePlace: View {
    let reader: BrainReader
    let open: (RecallRoute) -> Void
    /// Working On's read, for "Part of …" under a moment's header.
    var work: (any WorkReader)? = nil
    var calendar: Calendar = .current
    var now: @Sendable () -> Date = { Date() }

    var body: some View {
        LibraryLensPlace(lens: .code, reader: reader, work: work, open: open, calendar: calendar, now: now)
    }
}
