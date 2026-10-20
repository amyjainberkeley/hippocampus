// SPDX-License-Identifier: Apache-2.0
//
// How setup moves (SPEC 7.1 and 7.2), as numbers the screens, the preview
// renderer and the tests share. Opacity and position only, at most 300 ms,
// ease-out, no bounce, and every motion has a Reduce Motion form: a
// crossfade, or no motion at all.
//
// - Continue: the old screen fades out and drifts 12 pt left while the new
//   one fades in from 12 pt right, 280 ms, overlapping. Back mirrors it.
//   Under Reduce Motion both are a 200 ms crossfade.
// - Inside the new screen the title arrives first and the content 60 ms
//   later; nothing else staggers. Under Reduce Motion they come together.
// - The page dots: the active dot widens from 8 to 24 pt and the old one
//   narrows, 250 ms; instant under Reduce Motion.
// - The primary button's label crossfades in 150 ms and the button keeps
//   its width; a button that becomes enabled fades from 45% to full in
//   150 ms. Instant under Reduce Motion.
// - A permission turning on: its tile crossfades from blue to green in
//   220 ms, and "On" with its checkmark fades in while scaling from 0.85
//   to 1 in 200 ms. Under Reduce Motion it only fades.
// - Done fades setup out in 200 ms.
//
// The window never resizes between screens: what needs more room scrolls
// inside it, and the bottom bar never moves.

import Foundation

/// Which way setup moved: on, as Continue does, or back.
public enum ScreenMove: Equatable, Sendable {
    case forward
    case back

    /// The move from one screen to another: forward when the new one comes
    /// later in setup. Consent moves on to Try it; a permission found off
    /// at consent sends the person back to Permissions.
    public init(from old: OnboardingScreen, to new: OnboardingScreen) {
        self = new.rawValue >= old.rawValue ? .forward : .back
    }
}

/// Where a transition stands at one instant: what the leaving screen, the
/// arriving screen and the arriving screen's content show.
public struct ScreenTransitionState: Equatable, Sendable {
    public let outgoingOpacity: Double
    /// Points along x; negative is left.
    public let outgoingOffset: Double
    public let incomingOpacity: Double
    public let incomingOffset: Double
    /// The arriving screen's content under its title, on top of the
    /// screen's own fade.
    public let contentOpacity: Double
}

/// One move between screens, as SPEC 7.1 draws it.
public struct ScreenTransition: Equatable, Sendable {
    public let move: ScreenMove
    public let reduceMotion: Bool

    /// How far a screen drifts as it comes or goes.
    public static let drift: Double = 12
    public static let standardDuration: Double = 0.28
    public static let reduceMotionDuration: Double = 0.2
    /// The content arrives this long after the title.
    public static let titleLead: Double = 0.06

    public init(move: ScreenMove, reduceMotion: Bool) {
        self.move = move
        self.reduceMotion = reduceMotion
    }

    /// The whole move: both screens at once.
    public var duration: Double { reduceMotion ? Self.reduceMotionDuration : Self.standardDuration }

    /// Where the leaving screen drifts to: left going on, right going back.
    public var outgoingOffset: Double {
        reduceMotion ? 0 : (move == .forward ? -Self.drift : Self.drift)
    }

    /// Where the arriving screen comes in from: the right going on, the
    /// left going back.
    public var incomingOffset: Double {
        reduceMotion ? 0 : (move == .forward ? Self.drift : -Self.drift)
    }

    /// How long after the title the content starts arriving. Together under
    /// Reduce Motion.
    public var contentDelay: Double { reduceMotion ? 0 : Self.titleLead }

    /// The content's own fade, which ends with the screen's.
    public var contentDuration: Double { duration - contentDelay }

    /// The move `time` seconds in, with the ease-out every setup motion
    /// uses. The renderer draws frames from this; the screens animate to
    /// the same ends over the same times.
    public func state(at time: Double) -> ScreenTransitionState {
        let progress = OnboardingEasing.easeOut(time / duration)
        let contentProgress = contentDuration > 0
            ? OnboardingEasing.easeOut((time - contentDelay) / contentDuration) : progress
        return ScreenTransitionState(
            outgoingOpacity: 1 - progress,
            outgoingOffset: outgoingOffset * progress,
            incomingOpacity: progress,
            incomingOffset: incomingOffset * (1 - progress),
            contentOpacity: contentProgress
        )
    }
}

/// The page dots under setup (SPEC 7.1).
public enum ProgressDotsMotion {
    public static let dotWidth: Double = 8
    public static let activeWidth: Double = 24
    public static let height: Double = 8
    /// The active dot widens and the old one narrows together.
    public static let duration: Double = 0.25

    /// Nil under Reduce Motion: the dots change at once.
    public static func animationDuration(reduceMotion: Bool) -> Double? {
        reduceMotion ? nil : duration
    }
}

/// The primary button in the bottom bar (SPEC 7.1).
public enum PrimaryButtonMotion {
    /// Its label crossfades this long when it changes.
    public static let labelCrossfade: Double = 0.15
    /// Off, it shows at this opacity; on, it fades to full in `enableFade`.
    public static let disabledOpacity: Double = 0.45
    public static let enableFade: Double = 0.15

    /// Nil under Reduce Motion: the change is instant.
    public static func duration(_ seconds: Double, reduceMotion: Bool) -> Double? {
        reduceMotion ? nil : seconds
    }
}

/// A permission found on (SPEC 7.2).
public enum PermissionOnMotion {
    /// The row's tile crossfades from blue to the calm green.
    public static let tileCrossfade: Double = 0.22
    /// "On" with its checkmark fades in while it scales from this to 1.
    public static let checkmarkStartScale: Double = 0.85
    public static let checkmarkDuration: Double = 0.2

    /// The checkmark's scale `time` seconds after the row turned on. It
    /// only fades under Reduce Motion, so it starts at full size.
    public static func checkmark(at time: Double, reduceMotion: Bool) -> (opacity: Double, scale: Double) {
        let progress = OnboardingEasing.easeOut(time / checkmarkDuration)
        let scale = reduceMotion ? 1 : checkmarkStartScale + (1 - checkmarkStartScale) * progress
        return (progress, scale)
    }

    /// The green tile's share of the crossfade `time` seconds in.
    public static func tile(at time: Double) -> Double {
        OnboardingEasing.easeOut(time / tileCrossfade)
    }
}

/// Done (SPEC 7.4): setup fades out, then the app opens the window.
public enum SetupExitMotion {
    public static let fadeOut: Double = 0.2
}

/// The ease-out curve SwiftUI's `.easeOut` draws: the cubic Bézier with
/// control points (0, 0) and (0.58, 1).
public enum OnboardingEasing {
    /// Progress 0 to 1 along the curve for a time share 0 to 1, clamped.
    public static func easeOut(_ share: Double) -> Double {
        let x = min(max(share, 0), 1)
        if x == 0 || x == 1 { return x }
        // Solve x(s) = x for the curve's parameter s, then return y(s).
        let (x1, y1, x2, y2) = (0.0, 0.0, 0.58, 1.0)
        func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            let inverse = 1 - s
            return 3 * inverse * inverse * s * p1 + 3 * inverse * s * s * p2 + s * s * s
        }
        var low = 0.0, high = 1.0, s = x
        for _ in 0..<40 {
            s = (low + high) / 2
            if bezier(s, x1, x2) < x { low = s } else { high = s }
        }
        return bezier(s, y1, y2)
    }
}

/// Where setup's window goes and how tall it is (SPEC 7.7).
///
/// - It opens centred on the display with the pointer, so on a Mac with
///   several displays it comes up where the person is looking.
/// - It is 760 by 560, or on a short screen (a 13-inch MacBook Air at
///   Larger Text) as tall as the screen's visible frame less 40 pt: the
///   screen's content scrolls inside it and the bottom bar stays.
public enum SetupWindowFit {
    public static let width: Double = 760
    public static let height: Double = 560
    /// Room left between the window and the edges of the visible frame.
    public static let margin: Double = 40
    /// Never shorter than this: the title, a row and the bar.
    public static let minimumHeight: Double = 400

    /// The window's height on a screen whose visible frame is this tall.
    public static func height(visibleHeight: Double) -> Double {
        min(height, max(minimumHeight, visibleHeight - margin))
    }

    /// The display to open on: the one whose frame holds the pointer, else
    /// the first. Frames are in screen coordinates, `visible` without the
    /// menu bar and the Dock.
    public static func display(
        pointer: (x: Double, y: Double),
        screens: [(frame: SetupRect, visible: SetupRect)]
    ) -> SetupRect? {
        screens.first { $0.frame.contains(pointer.x, pointer.y) }?.visible ?? screens.first?.visible
    }

    /// Where a window of this size goes to sit centred in `visible`.
    public static func origin(width: Double, height: Double, in visible: SetupRect) -> (x: Double, y: Double) {
        ((visible.x + (visible.width - width) / 2).rounded(), (visible.y + (visible.height - height) / 2).rounded())
    }

    /// The window's frame, centred in `visible`.
    public static func frame(in visible: SetupRect) -> SetupRect {
        let windowHeight = height(visibleHeight: visible.height)
        let origin = origin(width: width, height: windowHeight, in: visible)
        return SetupRect(x: origin.x, y: origin.y, width: width, height: windowHeight)
    }
}

/// A rectangle in screen points, origin at the bottom left as AppKit has it.
public struct SetupRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(_ px: Double, _ py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }
}
