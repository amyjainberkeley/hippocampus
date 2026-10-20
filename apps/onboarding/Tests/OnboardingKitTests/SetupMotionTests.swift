import XCTest
@testable import OnboardingKit

/// How setup moves (SPEC 7.1, 7.2, 7.4): the numbers every screen, the
/// renderer and these tests share. Opacity and position only, within
/// 300 ms, and a Reduce Motion form for every motion.
final class SetupMotionTests: XCTestCase {
    func testContinueMovesForwardAndBackMovesBack() {
        XCTAssertEqual(ScreenMove(from: .welcome, to: .whatYouGet), .forward)
        XCTAssertEqual(ScreenMove(from: .promise, to: .tryIt), .forward, "consent moves on")
        XCTAssertEqual(ScreenMove(from: .promise, to: .permissions), .back, "a permission off at consent")
        XCTAssertEqual(ScreenMove(from: .whatYouGet, to: .welcome), .back)
    }

    func testTheOldScreenDriftsTheWaySetupGoesAndTheNewOneComesFromTheOtherSide() {
        let forward = ScreenTransition(move: .forward, reduceMotion: false)
        XCTAssertEqual(forward.outgoingOffset, -12, "left, going on")
        XCTAssertEqual(forward.incomingOffset, 12, "from the right")
        XCTAssertEqual(forward.duration, 0.28)
        let back = ScreenTransition(move: .back, reduceMotion: false)
        XCTAssertEqual(back.outgoingOffset, 12, "mirrored")
        XCTAssertEqual(back.incomingOffset, -12)
        XCTAssertEqual(back.duration, 0.28)
    }

    func testBothScreensMoveAtOnceAndEndTogether() {
        let move = ScreenTransition(move: .forward, reduceMotion: false)
        let start = move.state(at: 0)
        XCTAssertEqual(start.outgoingOpacity, 1)
        XCTAssertEqual(start.outgoingOffset, 0)
        XCTAssertEqual(start.incomingOpacity, 0)
        XCTAssertEqual(start.incomingOffset, 12)
        XCTAssertEqual(start.contentOpacity, 0)
        // Overlapping: halfway, both show.
        let middle = move.state(at: 0.14)
        XCTAssertGreaterThan(middle.outgoingOpacity, 0)
        XCTAssertGreaterThan(middle.incomingOpacity, 0.5, "ease-out: most of the way at half time")
        XCTAssertEqual(middle.outgoingOpacity + middle.incomingOpacity, 1, accuracy: 0.0001, "a crossfade")
        XCTAssertLessThan(middle.contentOpacity, middle.incomingOpacity, "the content follows the title")
        let end = move.state(at: 0.28)
        XCTAssertEqual(end.outgoingOpacity, 0)
        XCTAssertEqual(end.outgoingOffset, -12)
        XCTAssertEqual(end.incomingOpacity, 1)
        XCTAssertEqual(end.incomingOffset, 0)
        XCTAssertEqual(end.contentOpacity, 1, "and ends with it")
        XCTAssertEqual(move.state(at: 1), end, "nothing moves after")
    }

    func testTheContentArrivesSixtyMillisecondsAfterTheTitle() {
        let move = ScreenTransition(move: .forward, reduceMotion: false)
        XCTAssertEqual(move.contentDelay, 0.06)
        XCTAssertEqual(move.contentDelay + move.contentDuration, move.duration, accuracy: 0.0001)
        XCTAssertEqual(move.state(at: 0.06).contentOpacity, 0)
        XCTAssertGreaterThan(move.state(at: 0.06).incomingOpacity, 0, "the title is already arriving")
        XCTAssertGreaterThan(move.state(at: 0.1).contentOpacity, 0)
    }

    func testUnderReduceMotionEveryMoveIsA200MillisecondCrossfade() {
        for direction in [ScreenMove.forward, .back] {
            let move = ScreenTransition(move: direction, reduceMotion: true)
            XCTAssertEqual(move.duration, 0.2)
            XCTAssertEqual(move.outgoingOffset, 0, "nothing drifts")
            XCTAssertEqual(move.incomingOffset, 0)
            XCTAssertEqual(move.contentDelay, 0, "title and content together")
            for ms in stride(from: 0, through: 200, by: 20) {
                let state = move.state(at: Double(ms) / 1000)
                XCTAssertEqual(state.outgoingOffset, 0)
                XCTAssertEqual(state.incomingOffset, 0)
                XCTAssertEqual(state.contentOpacity, state.incomingOpacity, accuracy: 0.0001)
            }
        }
    }

    func testEveryMotionStaysWithin300Milliseconds() {
        for reduceMotion in [false, true] {
            XCTAssertLessThanOrEqual(ScreenTransition(move: .forward, reduceMotion: reduceMotion).duration, 0.3)
        }
        XCTAssertLessThanOrEqual(ProgressDotsMotion.duration, 0.3)
        XCTAssertLessThanOrEqual(PrimaryButtonMotion.labelCrossfade, 0.3)
        XCTAssertLessThanOrEqual(PrimaryButtonMotion.enableFade, 0.3)
        XCTAssertLessThanOrEqual(PermissionOnMotion.tileCrossfade, 0.3)
        XCTAssertLessThanOrEqual(PermissionOnMotion.checkmarkDuration, 0.3)
        XCTAssertLessThanOrEqual(SetupExitMotion.fadeOut, 0.3)
    }

    func testTheDotsWidenFrom8To24AndAreInstantUnderReduceMotion() {
        XCTAssertEqual(ProgressDotsMotion.dotWidth, 8)
        XCTAssertEqual(ProgressDotsMotion.activeWidth, 24)
        XCTAssertEqual(ProgressDotsMotion.duration, 0.25)
        XCTAssertEqual(ProgressDotsMotion.animationDuration(reduceMotion: false), 0.25)
        XCTAssertNil(ProgressDotsMotion.animationDuration(reduceMotion: true))
    }

    func testThePrimaryButtonCrossfadesItsLabelAndFadesInWhenItTurnsOn() {
        XCTAssertEqual(PrimaryButtonMotion.labelCrossfade, 0.15)
        XCTAssertEqual(PrimaryButtonMotion.enableFade, 0.15)
        XCTAssertEqual(PrimaryButtonMotion.disabledOpacity, 0.45)
        XCTAssertEqual(PrimaryButtonMotion.duration(0.15, reduceMotion: false), 0.15)
        XCTAssertNil(PrimaryButtonMotion.duration(0.15, reduceMotion: true), "no pulse, no bounce, instant")
    }

    func testThePrimaryButtonKeepsTheWidthOfEveryLabelItCanShowOnAScreen() {
        // Promise's button changes its words in place while the key is set
        // up; it keeps the widest so it never moves under the pointer.
        XCTAssertEqual(OnboardingCopy.primaryLabels(for: .promise, isReview: false),
                       ["Start Remembering", "Setting up encryption…"])
        XCTAssertEqual(OnboardingCopy.primaryLabels(for: .promise, isReview: true), ["Continue"])
        XCTAssertEqual(OnboardingCopy.primaryLabels(for: .welcome, isReview: false), ["Get Started"])
        XCTAssertEqual(OnboardingCopy.primaryLabels(for: .tryIt, isReview: false), ["Done"])
        for keyState: PrepareBrainViewModel.KeyState in [.checking, .generating, .ready, .failed("x")] {
            XCTAssertTrue(OnboardingCopy.primaryLabels(for: .promise, isReview: false)
                .contains(OnboardingCopy.promisePrimary(isReview: false, keyState: keyState)))
        }
    }

    func testAPermissionTurningOnGrowsFromEightyFivePercentAndOnlyFadesUnderReduceMotion() {
        XCTAssertEqual(PermissionOnMotion.tileCrossfade, 0.22)
        XCTAssertEqual(PermissionOnMotion.checkmarkStartScale, 0.85)
        XCTAssertEqual(PermissionOnMotion.checkmarkDuration, 0.2)
        let start = PermissionOnMotion.checkmark(at: 0, reduceMotion: false)
        XCTAssertEqual(start.opacity, 0)
        XCTAssertEqual(start.scale, 0.85)
        let midway = PermissionOnMotion.checkmark(at: 0.1, reduceMotion: false)
        XCTAssertGreaterThan(midway.scale, 0.85)
        XCTAssertLessThan(midway.scale, 1)
        let done = PermissionOnMotion.checkmark(at: 0.2, reduceMotion: false)
        XCTAssertEqual(done.opacity, 1)
        XCTAssertEqual(done.scale, 1)
        for ms in [0, 100, 200] {
            XCTAssertEqual(PermissionOnMotion.checkmark(at: Double(ms) / 1000, reduceMotion: true).scale, 1,
                           "no growing under Reduce Motion")
        }
        XCTAssertEqual(PermissionOnMotion.tile(at: 0), 0)
        XCTAssertEqual(PermissionOnMotion.tile(at: 0.22), 1)
    }

    func testTheEaseOutCurveIsSwiftUIs() {
        XCTAssertEqual(OnboardingEasing.easeOut(0), 0)
        XCTAssertEqual(OnboardingEasing.easeOut(1), 1)
        XCTAssertEqual(OnboardingEasing.easeOut(-1), 0)
        XCTAssertEqual(OnboardingEasing.easeOut(2), 1)
        // Cubic Bézier (0, 0) (0.58, 1): fast, then settling.
        XCTAssertEqual(OnboardingEasing.easeOut(0.5), 0.684, accuracy: 0.01)
        var last = 0.0
        for step in 1...20 {
            let value = OnboardingEasing.easeOut(Double(step) / 20)
            XCTAssertGreaterThanOrEqual(value, last, "never back, no bounce")
            XCTAssertLessThanOrEqual(value, 1, "no overshoot")
            last = value
        }
    }
}
