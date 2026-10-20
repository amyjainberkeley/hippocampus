import RecallUIKit
import SwiftUI

/// A Working On page (SPEC 3.2, SPEC-DELTA 3 and 4): everything about one
/// project or document. Where you left off with its screenshot and Resume,
/// its files, what was open alongside it, its meetings, and its own History
/// by day.
///
/// A seam for now: an empty page. It is built from the item's `work` read
/// with Working On.
struct WorkingOnItemPlace: View {
    let itemId: String
    let work: any WorkReader
    let reader: BrainReader
    let open: (RecallRoute) -> Void

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
