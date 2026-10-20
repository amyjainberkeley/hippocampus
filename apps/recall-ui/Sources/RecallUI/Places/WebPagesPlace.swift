import RecallUIKit
import SwiftUI

/// Web Pages (SPEC 3.5): pages read in a browser, one row per page across
/// days, newest first. A lens over History: its rows and detail, filtered to
/// web pages.
///
/// A seam for now: an empty page. It is built from the `work` read's pages,
/// with History's read as the fallback, with Working On.
struct WebPagesPlace: View {
    let work: any WorkReader
    let reader: BrainReader
    let open: (RecallRoute) -> Void

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
