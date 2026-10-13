import SwiftUI

/// The window's size and margins. Colours and type are in
/// `OnboardingDesign`.
enum OnboardingTheme {
    static let windowWidth: CGFloat = 760
    static let windowHeight: CGFloat = 560
    /// The text column: 760 less 48 on each side.
    static let contentMaxWidth: CGFloat = 664
    static let slidePadding: CGFloat = 48
    /// The title bar is hidden, so the window's buttons sit over the
    /// content. Nothing is drawn above this line.
    static let titleBarInset: CGFloat = 28
}
