// MCIDesignSystem.swift — cycle 8.48 Stripe-tuned design tokens.
//
// A single source of truth for MCI's SwiftUI surface. Ratifies the
// cycle-8.45 Raycast/Cotypist/Stripe peer study
// (`docs/research/2026-07-13-raycast-cotypist-stripe-peer-study.md`) into
// concrete Swift API so every view — HitRow, DetailPane, Search,
// PrivacyDashboard, GlobalRecallPopup, ActionPanel, onboarding — pulls
// from the same tokens.
//
// Design language, per §4 of the peer study:
//   - Typography: two-weight discipline (regular + semibold), Söhne-
//     inspired negative-tracking curve on display sizes (−1.4 → −0.2 px
//     across 56 → 20 pt), generous 1.5 line-height on body. We cannot
//     ship Söhne (Klim license), so we opt into SwiftUI's default
//     rounded/geometric SF via `Font.system` and apply the tracking
//     curve manually. Any near-Sohne (Inter, permissive clone) could
//     be swapped in later without changing token names.
//   - Color: MCI-teal accent (a mint-shifted indigo — `#3AFDC8` in
//     light, `#7AFFC1` in dark) on a monochrome navy/gray base. This
//     deliberately differentiates from Stripe's pure `#533afd` indigo
//     while borrowing the "one decisive accent, monochrome body"
//     discipline. Dark-mode-first because MCI's recall UI runs at
//     night alongside terminal-heavy workflows.
//   - Spacing: 8pt base grid — 2, 4, 8, 12, 16, 24, 32, 48, 64.
//   - Motion: opacity + transform only, ≤ 300ms, ease-in-out, no
//     bounce. `Motion.standard` (250ms) is the default; use `snap`
//     (150ms) for on-hover reveals and `deliberate` (350ms) sparingly
//     for onboarding transitions.
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
        // Semantic tokens — call these, not the raw hexes.
        public static let accent = dynamic(light: 0x2E9E7E, dark: 0x7AFFC1)
        public static let accentSubtle = dynamic(light: 0xE3F9F0, dark: 0x1A3D2E)
        public static let accentDim = dynamic(light: 0x53B69B, dark: 0x3D8060)

        public static let background = dynamic(light: 0xFFFFFF, dark: 0x0D0D0D)
        public static let surface = dynamic(light: 0xF7F8FA, dark: 0x1A1A1A)
        public static let surfaceElevated = dynamic(light: 0xFFFFFF, dark: 0x262626)

        public static let foreground = dynamic(light: 0x0D253D, dark: 0xE0E0E0)
        public static let foregroundSecondary = dynamic(light: 0x4A5768, dark: 0x999999)
        public static let foregroundMuted = dynamic(light: 0x8894A5, dark: 0x666666)

        public static let border = dynamic(light: 0xE3E7ED, dark: 0x333333)
        public static let borderStrong = dynamic(light: 0xC8D0DA, dark: 0x404040)

        public static let error = dynamic(light: 0xD64545, dark: 0xFF6B6B)
        public static let warning = dynamic(light: 0xD68B00, dark: 0xFFD93D)
        public static let success = dynamic(light: 0x2E8B57, dark: 0x7AFFC1)

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
    /// Typography scale. Applies Stripe's negative-tracking curve
    /// (§4.1 of the peer study): −1.4px @ 56pt down to −0.2px @ 20pt,
    /// then neutral or slightly positive on body/caption. Two weights
    /// only — regular (400) + semibold (600). Intermediate weights are
    /// intentionally NOT exposed.
    enum Font {
        /// Display-scale hero copy (e.g. onboarding). 32pt semibold,
        /// −1.0px tracking.
        public static let display = SwiftUI.Font.system(size: 32, weight: .semibold)
        public static let displayTracking: CGFloat = -1.0

        /// Section titles — 22pt semibold, −0.6px tracking.
        public static let title = SwiftUI.Font.system(size: 22, weight: .semibold)
        public static let titleTracking: CGFloat = -0.6

        /// Sub-titles — 17pt semibold, −0.3px tracking.
        public static let title2 = SwiftUI.Font.system(size: 17, weight: .semibold)
        public static let title2Tracking: CGFloat = -0.3

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

        /// 350ms ease-in-out. Use sparingly for onboarding transitions
        /// where the user's attention is deliberately being led.
        public static let deliberate: Animation = .easeInOut(duration: 0.35)

        /// Duration constants exposed for `withAnimation` sites that
        /// want to bind on a raw double. Prefer the pre-built
        /// `Animation` tokens above.
        public static let durationSnap: Double = 0.15
        public static let durationStandard: Double = 0.25
        public static let durationDeliberate: Double = 0.35
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

    /// Applies the Stripe-tuned tracking curve for a given font role.
    /// Wraps `.tracking()` so a view can write
    /// `.mciFont(.title)` instead of `.font(.title).tracking(-0.6)`
    /// and stay in sync when the curve shifts.
    func mciFont(_ role: MCIFontRole) -> some View {
        self.font(role.font).tracking(role.tracking)
    }
}

/// Enum bridge between the raw `MCI.Font` tokens and the tracking
/// curve. Keeps `.mciFont(.title)` at call sites clean; the numeric
/// tracking values live in `MCI.Font`.
public enum MCIFontRole {
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
        ("accent", 0x2E9E7E, 0x7AFFC1),
        ("accentSubtle", 0xE3F9F0, 0x1A3D2E),
        ("accentDim", 0x53B69B, 0x3D8060),
        ("background", 0xFFFFFF, 0x0D0D0D),
        ("surface", 0xF7F8FA, 0x1A1A1A),
        ("surfaceElevated", 0xFFFFFF, 0x262626),
        ("foreground", 0x0D253D, 0xE0E0E0),
        ("foregroundSecondary", 0x4A5768, 0x999999),
        ("foregroundMuted", 0x8894A5, 0x666666),
        ("border", 0xE3E7ED, 0x333333),
        ("borderStrong", 0xC8D0DA, 0x404040),
        ("error", 0xD64545, 0xFF6B6B),
        ("warning", 0xD68B00, 0xFFD93D),
        ("success", 0x2E8B57, 0x7AFFC1),
    ]
}
