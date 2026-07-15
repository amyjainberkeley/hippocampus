import SwiftUI

/// OnboardingDesign — the Hippocampus first-run design system.
///
/// Extracted in cycle 8.57 to close the gap between the (already-solid)
/// permission-choreography *behavior* and a flat visual surface. Encodes the
/// surface-polish rules distilled in `docs/research/2026-07-13-raycast-
/// cotypist-stripe-peer-study.md`:
///
///   • **Two-weight typography.** Headings are semibold/bold; body is
///     regular. Intermediate weights are avoided on new surfaces — Stripe's
///     "editorial air" comes from restraint, not a wall of `.medium`.
///   • **Negative-tracking curve.** Letter-spacing tightens with size
///     (≈ −1.3pt at display down to ≈ −0.2pt at 20pt), matching the Stripe
///     tracking ramp. Body stays at neutral tracking.
///   • **One decisive accent.** The historical `OnboardingTheme.accentBlue`
///     (#2563EB) stays the single hero hue — one filled CTA per screen.
///   • **8pt spacing grid** and **6–12pt radii** on all containers.
///   • **Calm motion budget.** Opacity + transform only, ≤ 300 ms, ease-out,
///     no bounce, always Reduce-Motion aware.
///
/// Every token is appearance-adaptive so the flow reads correctly in light
/// and dark. Zero external dependencies (ADR-0008) — pure SwiftUI.
///
/// `OnboardingTheme` (the pre-existing namespace many slides already call
/// into) forwards its accent + type helpers here, so this file is additive:
/// no call site had to change to adopt the tokens.
enum OnboardingDesign {

    // MARK: - Color

    enum Palette {
        /// The single decisive accent. Byte-for-byte the historical
        /// `OnboardingTheme.accentBlue` (#2563EB) so existing call sites,
        /// the app icon, and marketing screenshots stay in lockstep.
        static let accent = Color(
            red: Double(0x25) / 255,
            green: Double(0x63) / 255,
            blue: Double(0xEB) / 255
        )

        /// A lighter accent for gradients / glows on dark backdrops.
        static let accentBright = Color(
            red: Double(0x5B) / 255,
            green: Double(0x8D) / 255,
            blue: Double(0xF7) / 255
        )

        /// Tint fills for soft chips, selected key-caps, assurance rows.
        static let accentSoft = accent.opacity(0.12)
        static let accentHairline = accent.opacity(0.35)

        /// Thin card border — the Stripe "1px border, no shadow" container.
        /// Adaptive: barely-there on both appearances.
        static let hairline = Color.primary.opacity(0.10)

        /// Default calm card fill. Sits a hair above the window background
        /// without the muddy `secondary.opacity` look the slides used to
        /// reach for ad-hoc.
        static let cardFill = Color.primary.opacity(0.035)
        static let cardFillHover = Color.primary.opacity(0.06)

        /// Semantic status hues (kept sparse — success/attention/danger).
        static let success = Color.green
        static let attention = Color.orange
        static let danger = Color.red

        /// A muted "excluded / protected" hue for LivePreview blocked rows
        /// and denylist chips — reads as protection, not error. Low-chroma
        /// amber so it never alarms.
        static let excluded = Color.orange.opacity(0.85)
    }

    // MARK: - Typography

    /// Stripe-style tracking ramp: letter-spacing tightens as size grows.
    /// Anchored at (20pt → −0.2), (56pt → −1.3); linearly interpolated and
    /// clamped so tiny body text keeps neutral spacing and display text
    /// never over-tightens.
    static func tracking(forSize size: CGFloat) -> CGFloat {
        let minSize: CGFloat = 20, maxSize: CGFloat = 56
        let minTrack: CGFloat = -0.2, maxTrack: CGFloat = -1.3
        if size <= minSize { return 0 }
        let t = min(1, (size - minSize) / (maxSize - minSize))
        return minTrack + t * (maxTrack - minTrack)
    }

    enum TypeRamp {
        /// The celebratory bookend display (Welcome / Done) — bigger than
        /// `hero`, à la Raycast's "Your Mac. But Better."
        static func display(_ text: String) -> Text {
            Text(text)
                .font(.system(size: 52, weight: .bold))
                .tracking(OnboardingDesign.tracking(forSize: 52))
        }

        /// The oversized first-run hero — "Your memory, on your machine."
        /// Bold display with the tight tracking that keeps large type from
        /// feeling loose. Used on sub-hero surfaces (Permissions, hotkey).
        static func hero(_ text: String) -> Text {
            Text(text)
                .font(.system(size: 44, weight: .bold))
                .tracking(OnboardingDesign.tracking(forSize: 44))
        }

        /// Standard slide title. Replaces the old flat 28/bold.
        static func title(_ text: String) -> Text {
            Text(text)
                .font(.system(size: 30, weight: .semibold))
                .tracking(OnboardingDesign.tracking(forSize: 30))
        }

        /// Section / card heading.
        static func headline(_ text: String) -> Text {
            Text(text)
                .font(.system(size: 19, weight: .semibold))
                .tracking(OnboardingDesign.tracking(forSize: 19))
        }

        /// Body copy — regular weight, neutral tracking, comfortable size.
        static func body(_ text: String) -> Text {
            Text(text)
                .font(.system(size: 14, weight: .regular))
        }

        /// Secondary / supporting copy.
        static func caption(_ text: String) -> Text {
            Text(text)
                .font(.system(size: 12, weight: .regular))
        }

        /// The calm assurance sentence — the one bolded reassurance line in
        /// a `ReassuranceBanner` (Cotypist "neither stored nor sent").
        static func reassurance(_ text: String) -> Text {
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .tracking(OnboardingDesign.tracking(forSize: 16))
        }

        /// Tertiary / legal footnotes (retention warnings, "N of 13" a11y).
        /// Returns plain `Text` (font only) so it stays concatenable; the
        /// caller applies `.foregroundStyle(.tertiary)` at the view level.
        static func footnote(_ text: String) -> Text {
            Text(text)
                .font(.system(size: 11, weight: .regular))
        }

        /// Monospaced — tool names, bundle ids, code paths, timestamps.
        static func mono(_ text: String) -> Text {
            Text(text)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
        }
    }

    // MARK: - Spacing (8pt grid)

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
        static let huge: CGFloat = 64
    }

    // MARK: - Radius

    enum Radius {
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let large: CGFloat = 16
        static let pill: CGFloat = 999
    }

    // MARK: - Layout width clamps

    /// Content-width clamps. `prose` matches the historical
    /// `OnboardingTheme.contentMaxWidth` (600) so standard slides keep their
    /// line length; `hero` and `wide` open up for centered heroes and
    /// two-column layouts on the 1280-pt window.
    enum Width {
        static let prose: CGFloat = 600
        static let hero: CGFloat = 720
        static let wide: CGFloat = 960
    }

    // MARK: - Motion

    /// Calm motion tokens. Opacity + transform only, ≤ 300 ms, ease-out,
    /// no bounce. Use `resolve(_:reduceMotion:)` at the call site so every
    /// animation collapses to an instant change under Reduce Motion.
    enum Motion {
        static let quick: Animation = .easeOut(duration: 0.18)
        static let standard: Animation = .easeOut(duration: 0.28)
        static let gentle: Animation = .easeOut(duration: 0.4)

        /// Returns `nil` (no animation) when the user has asked for
        /// reduced motion, otherwise the supplied animation.
        static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : animation
        }

        /// One shared entrance transition — a gentle fade + rise that
        /// collapses to a plain fade (no offset) under Reduce Motion.
        static func entrance(reduceMotion: Bool) -> AnyTransition {
            reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6))
        }
    }
}
