import OnboardingKit
import SwiftUI

/// Welcome's demo: a small Mac screen where the three moments play, drawn
/// from the app's own surfaces (`ProductMiniatures.swift`). It draws the
/// frame it is given; `WelcomeSlide` keeps the time.
struct WelcomeDemo: View {
    let frame: DemoFrame
    /// Under Reduce Motion moments only fade, and nothing moves.
    var still = false

    static let size = CGSize(width: 584, height: 226)

    var body: some View {
        ZStack(alignment: .top) {
            MiniPalette.desktop
            VStack(spacing: 0) {
                MiniMenuBar()
                Spacer(minLength: 0)
            }
            moment
                .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
                .opacity(frame.isShown ? 1 : 0)
                .offset(y: still || frame.isShown ? 0 : entranceOffset)
                .animation(.easeOut(duration: 0.28), value: frame.isShown)
                .id(frame.moment)
                .transition(.opacity)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.3), value: frame.moment)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OnboardingCopy.welcomeDemoLabel)
    }

    /// A moment's window settles a little as it goes.
    private var entranceOffset: CGFloat { 6 }

    @ViewBuilder
    private var moment: some View {
        switch frame.moment {
        case .ask:
            ZStack(alignment: .top) {
                MiniMessageBehind()
                    .frame(width: 424, height: 176)
                    .padding(.top, 36)
                    // Ask has the person's attention once it is open.
                    .opacity(frame.askOpen ? 0.6 : 1)
                    .animation(.easeOut(duration: 0.28), value: frame.askOpen)
                MiniAskPanel(frame: frame)
                    .padding(.top, 28)
                    .opacity(frame.askOpen ? 1 : 0)
                    .offset(y: frame.askOpen || still ? 0 : -12)
                    .animation(.easeOut(duration: 0.28), value: frame.askOpen)
                    .animation(.easeOut(duration: 0.25), value: frame.showsAnswer)
                    .animation(.easeOut(duration: 0.25), value: frame.showsSource)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .today:
            MiniTodayWindow(frame: frame)
                .frame(width: 470, height: 182)
                .padding(.top, 30)
                .animation(.easeOut(duration: 0.3), value: frame.sessionsShown)
                .animation(.easeOut(duration: 0.3), value: frame.showsSessionCard)
        case .ai:
            // Wide enough that the reply keeps to one line, as a terminal
            // this size would show it.
            MiniAIWindow(frame: frame)
                .frame(width: 480, height: 160)
                .padding(.top, 30)
                .animation(.easeOut(duration: 0.28), value: frame.contextLinesShown)
                .animation(.easeOut(duration: 0.28), value: frame.showsReply)
        }
    }
}
