// MCIDesignSystem.swift — native memory-workspace design tokens.
//
// A single source of truth for MCI's SwiftUI surface. Every view —
// HitRow, DetailPane, Search, PrivacyDashboard, GlobalRecallPopup,
// ActionPanel, onboarding — pulls from the same tokens.
//
// Design language:
//   - Typography: native SF roles with regular + semibold weight only
//     and zero letter spacing so macOS controls keep their native fit.
//   - Color: approved memory palette — snow canvas, clear surface, ink,
//     graphite, cobalt action, and coral change marker. Dark appearance
//     uses semantic companions rather than forcing the whole app dark.
//   - Spacing: 8pt base grid — 2, 4, 8, 12, 16, 24, 32, 48, 64.
//   - Motion: opacity + transform only, ≤ 300ms, ease-in-out, no
//     bounce. `Motion.standard` (250ms) is the default; use `snap`
//     (150ms) for on-hover reveals and `deliberate` (300ms) sparingly.
//   - Shadow: subtle two-layer stack that reads as "expensive card,"
//     never as a MacOS-window drop-shadow. Skip entirely on inline
//     surfaces.
//
// No new dependencies. SwiftUI native only. Views apply tokens
// incrementally; the legacy `Color.brandXxx` aliases in
// `RecallUI/BrandTheme.swift` are retained as bridges to avoid a
// big-bang refactor.
//
// See `docs/design/design-system.md` for rationale + usage examples.

import Foundation
import SwiftUI

// MARK: - Namespace

/// Root namespace for MCI's design tokens. Views should read every
/// visual constant off `MCI.Color`, `MCI.Font`, `MCI.Spacing`,
/// `MCI.Motion`, `MCI.Shadow`, and `MCI.Radius`.
///
/// The namespace is a caseless enum by convention — this is the Swift
/// idiom for "no values, only static members." Nested types disambiguate
/// against SwiftUI's `Color`/`Font` without requiring an `import`
/// gymnastics dance at the call site.
public enum MCI {}

// MARK: - Color

public extension MCI {
    /// MCI color palette. Every token has an explicit light + dark hex
    /// so a snapshot test can pin them; SwiftUI resolves them at render
    /// time via `NSColor(name:dynamicProvider:)`.
    enum Color {
        public struct ApprovedPalette: Sendable, Equatable {
            public let snowCanvas: UInt32 = 0xF6F8FB
            public let clearSurface: UInt32 = 0xFFFFFF
            public let ink: UInt32 = 0x18212B
            public let graphite: UInt32 = 0x5F6975
            public let cobaltAction: UInt32 = 0x3568D4
            public let coralChangeMarker: UInt32 = 0xD96C5F
        }

        public static let approvedPalette = ApprovedPalette()

        // Semantic tokens — call these, not the raw hexes.
        public static let accent = dynamic(light: 0x3568D4, dark: 0x8AADFF)
        public static let accentSubtle = dynamic(light: 0xEAF1FF, dark: 0x182848)
        public static let accentDim = dynamic(light: 0x6F89C8, dark: 0xAEC4FF)

        public static let background = dynamic(light: 0xF6F8FB, dark: 0x10151B)
        public static let surface = dynamic(light: 0xFFFFFF, dark: 0x171D24)
        public static let surfaceElevated = dynamic(light: 0xFFFFFF, dark: 0x202833)

        public static let foreground = dynamic(light: 0x18212B, dark: 0xF0F4F8)
        public static let foregroundSecondary = dynamic(light: 0x5F6975, dark: 0xADB7C3)
        public static let foregroundMuted = dynamic(light: 0x8B96A3, dark: 0x7B8794)

        public static let border = dynamic(light: 0xDDE4EC, dark: 0x323C48)
        public static let borderStrong = dynamic(light: 0xC8D2DE, dark: 0x465262)

        public static let change = dynamic(light: 0xD96C5F, dark: 0xFF9A8F)
        public static let error = dynamic(light: 0xD96C5F, dark: 0xFF9A8F)
        public static let warning = dynamic(light: 0xB9822E, dark: 0xE7B767)
        public static let success = dynamic(light: 0x3568D4, dark: 0xAEC4FF)

        // Raw hex accessor used only for tests + docs. Prefer the
        // semantic tokens above at call sites.
        public static func hex(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            dynamic(light: light, dark: dark)
        }

        /// Builds a light/dark aware SwiftUI Color from two hex ints.
        /// Bridges to `NSColor(name:dynamicProvider:)` so the color
        /// updates live when the user flips appearance without a
        /// window rebuild.
        private static func dynamic(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            #if canImport(AppKit)
            return SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
            #else
            return SwiftUI.Color(hex: UInt(dark))
            #endif
        }
    }
}

// MARK: - Font

public extension MCI {
    /// Typography scale. Two weights only — regular (400) + semibold
    /// (600). Intermediate weights and custom tracking are intentionally
    /// not exposed.
    enum Font {
        /// Display-scale hero copy (e.g. onboarding). 32pt semibold.
        public static let display = SwiftUI.Font.system(size: 32, weight: .semibold)
        public static let displayTracking: CGFloat = 0

        /// Section titles — 22pt semibold.
        public static let title = SwiftUI.Font.system(size: 22, weight: .semibold)
        public static let titleTracking: CGFloat = 0

        /// Sub-titles — 17pt semibold.
        public static let title2 = SwiftUI.Font.system(size: 17, weight: .semibold)
        public static let title2Tracking: CGFloat = 0

        /// Body copy — 14pt regular, neutral tracking, 1.5 line-height.
        public static let body = SwiftUI.Font.system(size: 14, weight: .regular)
        public static let bodyTracking: CGFloat = 0

        /// Emphasized body — 14pt semibold. For row titles / labels.
        public static let bodyStrong = SwiftUI.Font.system(size: 14, weight: .semibold)

        /// Caption — 12pt regular. Metadata, timestamps, chip labels.
        public static let caption = SwiftUI.Font.system(size: 12, weight: .regular)

        /// Footnote — 11pt regular. Least prominent metadata.
        public static let footnote = SwiftUI.Font.system(size: 11, weight: .regular)

        /// Monospaced caption for numeric metadata (scores, IDs, ts).
        public static let mono = SwiftUI.Font.system(size: 11, weight: .regular, design: .monospaced)
    }
}

// MARK: - Spacing

public extension MCI {
    /// 8pt base grid, exposed as CGFloat constants. Use these instead
    /// of literal padding numbers so ratcheting the whole app to a
    /// tighter/looser rhythm is a single-file edit.
    enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 48
        public static let hero: CGFloat = 64
    }
}

// MARK: - Radius

public extension MCI {
    /// Corner-radius scale. Stripe uses 4–6 for controls, 10–14 for
    /// modal cards. We honor the same range so the density feels
    /// familiar without directly copying.
    enum Radius {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 6
        public static let m: CGFloat = 8
        public static let l: CGFloat = 12
        public static let xl: CGFloat = 14
    }
}

// MARK: - Motion

public extension MCI {
    /// Animation tokens. Motion budget per §4.4 of the peer study:
    /// opacity + transform only, ≤ 300ms, ease-in-out (no bounce, no
    /// elastic). `standard` is the default; other tokens are named for
    /// intent so a reviewer can catch misuse.
    enum Motion {
        /// 250ms ease-in-out. Default for panel show/hide, selection
        /// changes, hover reveals.
        public static let standard: Animation = .easeInOut(duration: 0.25)

        /// 150ms ease-out. On-hover reveals, tiny opacity flips.
        public static let snap: Animation = .easeOut(duration: 0.15)

        /// 300ms ease-in-out. Use sparingly for onboarding transitions
        /// where the user's attention is deliberately being led.
        public static let deliberate: Animation = .easeInOut(duration: 0.30)

        /// Duration constants exposed for `withAnimation` sites that
        /// want to bind on a raw double. Prefer the pre-built
        /// `Animation` tokens above.
        public static let durationSnap: Double = 0.15
        public static let durationStandard: Double = 0.25
        public static let durationDeliberate: Double = 0.30
    }
}

// MARK: - Shadow

public extension MCI {
    /// Shadow presets. Stripe's card style is intentionally NEAR-FLAT
    /// (§4.5) — a subtle drop is used, but never a MacOS-window
    /// pillow. `card` is the default; `modal` is used ONLY for the
    /// Action Panel + Global Recall popup, which float above app
    /// chrome. `none` is a token so a view can opt out explicitly.
    struct Shadow: Sendable {
        public let color: SwiftUI.Color
        public let radius: CGFloat
        public let x: CGFloat
        public let y: CGFloat

        public static let none = Shadow(color: .clear, radius: 0, x: 0, y: 0)
        public static let card = Shadow(
            color: SwiftUI.Color.black.opacity(0.08), radius: 4, x: 0, y: 1
        )
        public static let modal = Shadow(
            color: SwiftUI.Color.black.opacity(0.35), radius: 24, x: 0, y: 8
        )
    }
}

// MARK: - View modifiers

public extension View {
    /// Applies an `MCI.Shadow` preset. `.mciShadow(.none)` is a no-op
    /// so views can conditionally opt in without an if-else branch.
    func mciShadow(_ shadow: MCI.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }

    /// Applies the native zero-tracking font role.
    /// Wraps `.tracking()` so a view can write
    /// `.mciFont(.title)` without repeating token plumbing.
    func mciFont(_ role: MCIFontRole) -> some View {
        self.font(role.font).tracking(role.tracking)
    }
}

/// Enum bridge between the raw `MCI.Font` tokens and the zero-tracking
/// native type surface.
public enum MCIFontRole: CaseIterable {
    case display, title, title2, body, bodyStrong, caption, footnote, mono

    public var font: Font {
        switch self {
        case .display: return MCI.Font.display
        case .title: return MCI.Font.title
        case .title2: return MCI.Font.title2
        case .body: return MCI.Font.body
        case .bodyStrong: return MCI.Font.bodyStrong
        case .caption: return MCI.Font.caption
        case .footnote: return MCI.Font.footnote
        case .mono: return MCI.Font.mono
        }
    }

    public var tracking: CGFloat {
        switch self {
        case .display: return MCI.Font.displayTracking
        case .title: return MCI.Font.titleTracking
        case .title2: return MCI.Font.title2Tracking
        case .body, .bodyStrong: return MCI.Font.bodyTracking
        case .caption, .footnote, .mono: return 0
        }
    }
}

// MARK: - Hex bridge for tests

#if canImport(AppKit)
extension NSColor {
    /// Test-only hex initializer mirroring the `Color(hex:)` helper in
    /// `BrandTheme.swift`. Kept here so the `MCI.Color` tokens can
    /// resolve dynamically without leaking a AppKit import into every
    /// call site.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
#endif

// MARK: - Snapshot pin API (used by tests)

public extension MCI.Color {
    /// Every semantic token, paired with its light + dark hex. Used by
    /// `MCIDesignSystemTests` to assert we don't accidentally shift a
    /// token via a merge-conflict resolve. Keep in sync with the
    /// declared static tokens above.
    static let allTokens: [(name: String, light: UInt32, dark: UInt32)] = [
        ("accent", 0x3568D4, 0x8AADFF),
        ("accentSubtle", 0xEAF1FF, 0x182848),
        ("accentDim", 0x6F89C8, 0xAEC4FF),
        ("background", 0xF6F8FB, 0x10151B),
        ("surface", 0xFFFFFF, 0x171D24),
        ("surfaceElevated", 0xFFFFFF, 0x202833),
        ("foreground", 0x18212B, 0xF0F4F8),
        ("foregroundSecondary", 0x5F6975, 0xADB7C3),
        ("foregroundMuted", 0x8B96A3, 0x7B8794),
        ("border", 0xDDE4EC, 0x323C48),
        ("borderStrong", 0xC8D2DE, 0x465262),
        ("change", 0xD96C5F, 0xFF9A8F),
        ("error", 0xD96C5F, 0xFF9A8F),
        ("warning", 0xB9822E, 0xE7B767),
        ("success", 0x3568D4, 0xAEC4FF),
    ]
}

public extension MCI {
    enum Workspace {
        public struct Destination: Sendable, Equatable, Identifiable {
            public let id: String
            public let title: String
            public let systemImage: String
            public let requiresSourceAccess: Bool
            public let keyboardShortcut: String

            public init(
                id: String,
                title: String,
                systemImage: String,
                requiresSourceAccess: Bool,
                keyboardShortcut: String
            ) {
                self.id = id
                self.title = title
                self.systemImage = systemImage
                self.requiresSourceAccess = requiresSourceAccess
                self.keyboardShortcut = keyboardShortcut
            }
        }

        public struct HistoricalMetric: Sendable, Equatable {
            public let title: String
            public let value: String
            public let detail: String

            public init(title: String, value: String, detail: String) {
                self.title = title
                self.value = value
                self.detail = detail
            }
        }

        public static let primaryDestinations: [Destination] = [
            .init(
                id: "now",
                title: "Now",
                systemImage: "sparkle.magnifyingglass",
                requiresSourceAccess: false,
                keyboardShortcut: "1"
            ),
            .init(
                id: "search",
                title: "Search",
                systemImage: "magnifyingglass",
                requiresSourceAccess: true,
                keyboardShortcut: "2"
            ),
            .init(
                id: "timeline",
                title: "Timeline",
                systemImage: "clock",
                requiresSourceAccess: true,
                keyboardShortcut: "3"
            ),
            .init(
                id: "episodes",
                title: "Episodes",
                systemImage: "rectangle.stack",
                requiresSourceAccess: true,
                keyboardShortcut: "4"
            ),
            .init(
                id: "briefs",
                title: "Briefs",
                systemImage: "doc.text",
                requiresSourceAccess: true,
                keyboardShortcut: "5"
            ),
        ]

        public static let secondaryDestinations: [Destination] = [
            .init(
                id: "sources",
                title: "Sources",
                systemImage: "link.badge.plus",
                requiresSourceAccess: true,
                keyboardShortcut: "6"
            ),
            .init(
                id: "privacy",
                title: "Privacy",
                systemImage: "lock.shield",
                requiresSourceAccess: false,
                keyboardShortcut: "7"
            ),
            .init(
                id: "settings",
                title: "Settings",
                systemImage: "gearshape",
                requiresSourceAccess: false,
                keyboardShortcut: "8"
            ),
        ]

        public static let allDestinations = primaryDestinations + secondaryDestinations

        public static func destination(forKeyboardShortcut shortcut: String) -> Destination? {
            allDestinations.first { $0.keyboardShortcut == shortcut }
        }

        public static func historicalEventMetric(for summary: SummaryStats) -> HistoricalMetric {
            HistoricalMetric(
                title: "Stored events",
                value: String(summary.totalEvents),
                detail: "Historical memory rows"
            )
        }

        public static func recentKeyframes(from hits: [Hit]) -> [Hit] {
            hits.filter { hit in
                guard let path = hit.thumbnailPath else { return false }
                return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        public static func keyframeCountLabel(_ count: Int) -> String {
            "\(count) \(count == 1 ? "keyframe" : "keyframes")"
        }
    }
}
