// SPDX-License-Identifier: Apache-2.0
//
// AskPanelPlacement.swift — where Ask hangs (spec-shell S1): under the top
// bar of the screen the pointer is on, centred, and never taller than 60% of
// the space under the bar. Pure numbers in AppKit's bottom-left screen
// coordinates, so every display arrangement is tested without a screen.

import CoreGraphics
import Foundation

public struct AskPanelPlacement: Equatable, Sendable {
    /// One display, as `NSScreen` reports it.
    public struct Screen: Equatable, Sendable {
        public let frame: CGRect
        public let visibleFrame: CGRect
        /// `safeAreaInsets.top`: the notch, or 0.
        public let safeAreaTop: CGFloat

        public init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat = 0) {
            self.frame = frame
            self.visibleFrame = visibleFrame
            self.safeAreaTop = safeAreaTop
        }
    }

    public static let preferredWidth: CGFloat = 700
    public static let tallest: CGFloat = 616
    /// The search row: the panel is never shorter.
    public static let shortest: CGFloat = 60
    public static let gapUnderBar: CGFloat = 8
    public static let margin: CGFloat = 12
    public static let shareOfSpaceUnderBar: CGFloat = 0.6
    /// The search row and the footer, which the content area does not get.
    public static let chromeHeight: CGFloat = 96
    public static let shortestContent: CGFloat = 160

    /// The panel's top edge, which stays put while it grows downward.
    public let top: CGFloat
    public let x: CGFloat
    public let width: CGFloat
    /// The tallest the panel may be on this screen.
    public let maxHeight: CGFloat

    public init(screen: Screen) {
        let f = screen.frame
        let v = screen.visibleFrame
        // The menu bar when it shows; the notch when the bar is hidden on a
        // notched display; 0 on a display with neither.
        let topInset = max(f.maxY - v.maxY, screen.safeAreaTop)
        top = f.maxY - topInset - Self.gapUnderBar
        width = min(Self.preferredWidth, v.width - 2 * Self.margin)
        // Centred on the whole display, which is under the notch on a
        // built-in one, then kept inside the visible area.
        x = min(max(f.midX - width / 2, v.minX + Self.margin), v.maxX - width - Self.margin)
        maxHeight = min(Self.tallest, ((top - v.minY - Self.margin) * Self.shareOfSpaceUnderBar).rounded(.down))
    }

    /// The display under `pointer`, else the main one, else the first.
    public static func screen(containing pointer: CGPoint, in screens: [Screen], main: Screen?) -> Screen? {
        screens.first { mouse(pointer, isIn: $0.frame) } ?? main ?? screens.first
    }

    /// `NSMouseInRect` for an unflipped rect: the top edge counts and the
    /// bottom edge does not, so a pointer on the top row of a display (in the
    /// menu bar) is on that display.
    public static func mouse(_ point: CGPoint, isIn rect: CGRect) -> Bool {
        point.x >= rect.minX && point.x < rect.maxX && point.y > rect.minY && point.y <= rect.maxY
    }

    /// The frame for content `height` tall: hung from `top`, capped at
    /// `maxHeight`; anything taller scrolls.
    public func frame(height: CGFloat) -> CGRect {
        let h = max(Self.shortest, min(height, maxHeight))
        return CGRect(x: x, y: top - h, width: width, height: h)
    }

    /// The most the content area between the search row and the footer may
    /// take.
    public var maxContentHeight: CGFloat {
        max(Self.shortestContent, maxHeight - Self.chromeHeight)
    }
}

/// How Ask arrives: a short drop from just above its place, or, with Reduce
/// Motion, a fade in place (spec-shell S1).
public struct AskPanelEntrance: Equatable, Sendable {
    /// How far above its place it starts.
    public let rise: CGFloat
    public let duration: TimeInterval

    public init(reduceMotion: Bool) {
        rise = reduceMotion ? 0 : 12
        duration = reduceMotion ? 0.10 : 0.16
    }

    /// Where the entrance starts, for a panel that ends at `frame`.
    public func start(for frame: CGRect) -> CGRect {
        frame.offsetBy(dx: 0, dy: rise)
    }
}

/// Whether closing Ask should also hide Hippocampus (spec-shell S1, D14).
///
/// A link that opened Ask activated the app; hiding it gives focus back to the
/// app the person was in. Any visible titled window, Preferences included,
/// means Hippocampus is in use and stays. Preferences is a panel that can
/// never become main, so asking `canBecomeMain` missed it and hid it.
public enum AskPanelDismissal {
    public struct Window: Equatable, Sendable {
        public let isVisible: Bool
        public let isTitled: Bool

        public init(isVisible: Bool, isTitled: Bool) {
            self.isVisible = isVisible
            self.isTitled = isTitled
        }
    }

    /// `otherWindows` are the app's windows other than Ask itself.
    public static func shouldHideApp(appIsActive: Bool, otherWindows: [Window]) -> Bool {
        appIsActive && !otherWindows.contains { $0.isVisible && $0.isTitled }
    }

    /// What asked Ask to open. The key toggles it; the menu and a
    /// `hippocampus://ask` link only ever show it (RULINGS S12).
    public enum Opening: Equatable, Sendable {
        case key, menu, link
    }

    /// Whether this request closes a visible panel instead of showing it.
    public static func closes(_ opening: Opening, visible: Bool) -> Bool {
        opening == .key && visible
    }

    /// Opening a link activates Hippocampus, which can take the keyboard
    /// from Ask a moment after it shows. That is not the person clicking
    /// away, so for this long Ask keeps the keyboard instead of closing.
    public static let linkActivationGrace: TimeInterval = 1

    /// Whether losing the keyboard closes Ask, given the seconds since a
    /// link last opened it.
    public static func closesOnResignKey(sinceLinkOpen: TimeInterval?) -> Bool {
        guard let sinceLinkOpen else { return true }
        return !(0..<linkActivationGrace).contains(sinceLinkOpen)
    }
}
