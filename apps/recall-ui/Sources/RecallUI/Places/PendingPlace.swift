import RecallUIKit
import SwiftUI

/// Overview and You until their own views are wired into the sidebar
/// (`Places/OverviewPlace.swift`, `Places/YouPlace.swift`). It shows the
/// place's name and nothing else, and reads nothing.
struct PendingPlace: View {
    let title: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(UserFacingCopy.pendingPlaceTitle)
        )
        .foregroundStyle(Color.brandFgSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.brandBgPrimary)
    }
}
