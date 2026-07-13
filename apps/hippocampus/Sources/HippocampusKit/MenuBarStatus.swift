// SPDX-License-Identifier: TBD-private
//
// MenuBarStatus — status-light rendering for the menu-bar icon.
//
// Ships pattern #3 (P0) from the Raycast/Cotypist peer study
// (docs/research/2026-07-13-raycast-cotypist-stripe-peer-study.md) and
// closes polish gap #1 from the cycle 8.44 product-readiness audit
// ("No 'recording active' pulse in the menu-bar icon").
//
// Prior UX (see HippocampusApp.MenuBarIcon): a single template glyph +
// an `exclamationmark.circle.fill` swap on `.crashed`. Users had no
// ambient signal for whether capture was actively running, paused by
// them, or wedged in an error state that hadn't yet flipped the
// supervisor to `.crashed` (e.g. TCC revoked mid-run, disk full,
// integrity-check failure surfaced via `helper_health.jsonl`). This
// file derives four visually distinct states from `SupervisorState`
// (+ an optional error reason) and hands the current one to a small
// SwiftUI view that owns the pulse animation.
//
// Constraints (see agent brief):
//   - UI-only. No changes to capture / OCR cascade / XPC surface /
//     entitlements / redaction / notarization / Gatekeeper /
//     mci.sqlite.
//   - No new bridge into MCICaptureHelper's XPC surface — status is
//     derived from the existing @Published `ProcessSupervisor.state`
//     + `HealthSnapshot` (both already reflect helper heartbeats via
//     `HealthSnapshot.readFromLog` on the `helper-health.jsonl`
//     ring).
//   - No telemetry. The status is a pure function of local state.
//   - Pulse must be near-zero on battery. We use SwiftUI's
//     `.animation` driver against a 2 s `Timer.publish` — one wake
//     per two seconds is well below display-link cost (~120 Hz) and
//     inside the NSStatusItem's own draw budget.

import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The four visual states encoded by the menu-bar icon.
///
/// Precedence when multiple could apply (checked top-down by
/// `MenuBarStatus.derive`):
///
///   1. `.error` — any hard failure signal (supervisor `.crashed`,
///      integrity-check failure, TCC revoked) wins over everything
///      else. The user needs to see this above all.
///   2. `.paused` — user-initiated pause (`SupervisorState.paused`).
///   3. `.recording` — supervisor `.running`. This is the pulse case.
///   4. `.idle` — everything else (`.idle`, `.starting`, `.stopped`).
public enum MenuBarStatus: Equatable, Sendable {
    case idle
    case recording
    case paused
    case error(reason: String)

    /// Short label rendered in the drop-down header row + used in
    /// tests to check state distinctness.
    public var displayText: String {
        switch self {
        case .idle: return "Idle"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .error: return "Error"
        }
    }

    /// The dot color to render next to the header row text.
    /// Matches the overlay dot / border color on the icon so the two
    /// surfaces read as the same signal.
    public var indicatorColor: Color {
        switch self {
        case .idle: return .secondary
        case .recording: return .green
        case .paused: return .yellow
        case .error: return .red
        }
    }

    /// Whether the icon should pulse. Only `.recording` pulses — this
    /// is the "capture is live" ambient signal from the Raycast study.
    public var shouldPulse: Bool {
        if case .recording = self { return true }
        return false
    }

    /// Derive from the current supervisor state + optional error
    /// overrides. `integrityError` and `tccRevokedSurface` are `nil`
    /// in the common case; when either is non-nil it forces `.error`
    /// regardless of the underlying supervisor state.
    ///
    /// Precedence when multiple errors overlap:
    ///   1. `tccRevokedSurface` — TCC revoke is user-recoverable in
    ///      one click, and the actionable notification hangs off THIS
    ///      reason string. Surface it first.
    ///   2. `integrityError` — DB integrity failure, wired separately.
    ///   3. `.crashed(reason)` from the supervisor.
    ///
    /// Cycle 8.45 audit risk #2: `tccRevokedSurface` is populated from
    /// the `helper_health tcc_revoked=<surface>` breadcrumb the helper
    /// emits via `TCCHelperHealth.line(...)`. The app-side status
    /// coordinator maps the enum to the human-readable reason string
    /// via `TCCRevokedReason`.
    public static func derive(
        from state: SupervisorState,
        integrityError: String? = nil,
        tccRevokedSurface: TCCRevokedReason? = nil
    ) -> MenuBarStatus {
        if let reason = tccRevokedSurface {
            return .error(reason: reason.menuBarReason)
        }
        if let reason = integrityError {
            return .error(reason: reason)
        }
        switch state {
        case .crashed(let reason):
            return .error(reason: reason)
        case .paused:
            return .paused
        case .running:
            return .recording
        case .idle, .starting, .stopped:
            return .idle
        }
    }
}

// MARK: - TCC revoked reason (cycle 8.45 audit risk #2)

/// Per-surface human-readable copy for the menu-bar red-pill + the
/// user-facing notification (`TCCRevokedNotifier`). Kept as an enum
/// (rather than plain strings) so the surface identity round-trips
/// through the app: the notification click-action deep-links to the
/// correct System Settings pane per `settingsPaneURLString` below.
public enum TCCRevokedReason: String, Sendable, Equatable, CaseIterable {
    case screenRecording
    case accessibility
    case fullDiskAccess
    case automation

    /// Short reason string embedded in `MenuBarStatus.error(reason:)`.
    /// Rendered in the drop-down header + read by VoiceOver via
    /// `MenuBarStatusLabel.accessibilityLabel`.
    public var menuBarReason: String {
        switch self {
        case .screenRecording: return "Screen Recording revoked"
        case .accessibility: return "Accessibility revoked"
        case .fullDiskAccess: return "Full Disk Access revoked"
        case .automation: return "Automation revoked"
        }
    }

    /// Human-readable title for the user-facing notification.
    public var notificationTitle: String {
        return "Hippocampus can't record"
    }

    /// Human-readable body for the user-facing notification. Explains
    /// why capture stopped in one plain sentence + tells the user the
    /// button re-grants.
    public var notificationBody: String {
        switch self {
        case .screenRecording:
            return "Screen Recording permission was revoked in System Settings. Click to re-grant."
        case .accessibility:
            return "Accessibility permission was revoked in System Settings. Click to re-grant."
        case .fullDiskAccess:
            return "Full Disk Access permission was revoked in System Settings. Click to re-grant."
        case .automation:
            return "Automation permission was revoked in System Settings. Click to re-grant."
        }
    }

    /// Deep-link URL string for the notification's action button. The
    /// `x-apple.systempreferences:` scheme drops the user directly on
    /// the correct pane; on macOS 13+ System Settings honours the
    /// anchor. NOT parsed into a real `URL` here so this type stays
    /// portable across targets that don't import `Foundation.URL`.
    public var settingsPaneURLString: String {
        switch self {
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .fullDiskAccess:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .automation:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        }
    }

    /// Parse the surface identifier the helper emits via
    /// `helper_health tcc_revoked=<surface>` (see
    /// `MCICaptureHelperKit/TCCHelperHealth.line(...)`). Returns nil
    /// for unknown identifiers so a future helper that adds a new
    /// surface without a corresponding app update cannot crash the
    /// app-side parser — the unknown revoke is simply ignored (the
    /// helper's own pause still holds).
    public static func fromHealthLogSurface(_ raw: String) -> TCCRevokedReason? {
        return TCCRevokedReason(rawValue: raw)
    }
}

// MARK: - View

/// The label SwiftUI hands to `MenuBarExtra`. Wraps
/// `MenuBarStatusIcon` (the raw NSImage renderer) in a view that owns
/// the pulse animation and the overlay glyphs.
///
/// Pulse implementation: a `TimelineView` on `.periodic(by: 2.0)`
/// fires exactly once every 2 seconds — this is a plain
/// Core-Foundation timer under the hood, NOT a display-link. Each
/// tick alternates the target opacity between 1.0 and 0.7, and the
/// `.animation(.easeInOut(duration: 2.0))` modifier lets Core
/// Animation interpolate the layer opacity on GPU with no CPU
/// wake-ups between ticks. Total cost: one main-thread callback per
/// 2 s, plus the CA implicit animation the OS was going to run
/// anyway. This is the "CALayer + implicit animation, not display
/// link" approach the agent brief calls for. When
/// `shouldPulse == false` we pin opacity to 1.0 and don't install a
/// schedule at all.
public struct MenuBarStatusLabel: View {
    public let status: MenuBarStatus

    /// Pulse period: opacity ping-pongs between `pulseMin` and 1.0
    /// with this cadence. 2 s matches the agent brief.
    static let pulsePeriod: TimeInterval = 2.0
    static let pulseMin: Double = 0.7

    public init(status: MenuBarStatus) {
        self.status = status
    }

    public var body: some View {
        Group {
            if status.shouldPulse {
                TimelineView(.periodic(from: .now, by: Self.pulsePeriod)) { context in
                    iconImage
                        .opacity(Self.pulseOpacity(at: context.date))
                        .animation(
                            .easeInOut(duration: Self.pulsePeriod),
                            value: Self.pulseOpacity(at: context.date)
                        )
                }
            } else {
                iconImage.opacity(1.0)
            }
        }
        .accessibilityLabel("Hippocampus — \(status.displayText)")
    }

    /// Alternates between `pulseMin` and 1.0 on `pulsePeriod`
    /// boundaries. Together with `.easeInOut(duration: pulsePeriod)`
    /// this produces a smooth breathing curve — the animation
    /// modifier interpolates the endpoints, so we only need to
    /// deliver the target value, not the continuous curve. Pure
    /// function → trivially testable.
    static func pulseOpacity(at date: Date) -> Double {
        let period = pulsePeriod * 2.0  // full cycle = min → max → min
        let t = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period)
        return t < pulsePeriod ? 1.0 : pulseMin
    }

    @ViewBuilder
    private var iconImage: some View {
        #if canImport(AppKit)
        Image(nsImage: MenuBarStatusIcon.image(for: status))
        #else
        Image(systemName: "brain.head.profile")
        #endif
    }
}

// MARK: - NSImage factory

#if canImport(AppKit)

/// Composes the base template glyph with per-state overlays. Called
/// from `MenuBarStatusLabel` and from tests (which check pixel-level
/// distinctness across the four states).
///
/// The base template is
/// `HippocampusApp.MenuBarIcon.templateImage` (loaded from
/// `Contents/Resources/statusbar-icon.png` at bundle time). We
/// duplicate the lookup here so `HippocampusKit` doesn't depend on
/// the executable target — the load falls back to a 22×22 blank
/// canvas if the resource is missing (unit tests, headless CI).
public enum MenuBarStatusIcon {

    /// Canonical NSStatusItem size on macOS 14+. Matches the
    /// existing MenuBarIcon fallback.
    static let baseSize = NSSize(width: 22, height: 22)

    public static func image(for status: MenuBarStatus) -> NSImage {
        let base = loadBaseTemplate()
        switch status {
        case .idle:
            // Slightly muted; NSStatusItem template tinting already
            // adapts to the menu bar, but a subtle alpha communicates
            // "not actively capturing" without going grey-out.
            return withAlpha(base, alpha: 0.55)
        case .recording:
            // Pulse handled at the view level; the base glyph is
            // untouched here so the animation reads as opacity change
            // rather than a jerky glyph swap.
            return base
        case .paused:
            return overlay(base: base, glyph: "pause.fill", tint: nil)
        case .error:
            return overlay(base: base, glyph: "circle.fill", tint: .systemRed)
        }
    }

    static func loadBaseTemplate() -> NSImage {
        if let bundled = NSImage(named: "statusbar-icon") {
            bundled.isTemplate = true
            return bundled
        }
        // Test/headless fallback: draw a filled rounded rect so the
        // downstream compositions have visible pixels to differ on.
        // Never taken in the shipped .app (statusbar-icon.png is in
        // Resources/); exists so `swift test` doesn't rely on the
        // resource pipeline.
        let img = NSImage(size: baseSize, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Idle: bake a lower alpha into the template. Bake (not
    /// `.opacity` at the view layer) so NSStatusItem's template tint
    /// path sees "muted" content and doesn't compete with dark/light-
    /// bar tinting for the same signal.
    private static func withAlpha(_ image: NSImage, alpha: CGFloat) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: image.size), from: .zero,
            operation: .sourceOver, fraction: alpha
        )
        out.unlockFocus()
        out.isTemplate = false
        return out
    }

    /// Draws `base` full-size then stamps an SF Symbol `glyph` into
    /// the bottom-right quadrant. `tint == nil` leaves the glyph as a
    /// template (menu bar tints it); otherwise the tint is baked (the
    /// red error dot must stay red regardless of menu-bar mode).
    private static func overlay(base: NSImage, glyph: String, tint: NSColor?) -> NSImage {
        let size = base.size
        let out = NSImage(size: size)
        out.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        let overlaySize = NSSize(width: size.width * 0.55, height: size.height * 0.55)
        let overlayRect = NSRect(
            x: size.width - overlaySize.width, y: 0,
            width: overlaySize.width, height: overlaySize.height
        )
        if let symbol = NSImage(systemSymbolName: glyph, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: overlaySize.height, weight: .bold)
            let configured = symbol.withSymbolConfiguration(config) ?? symbol
            if let tint {
                let tinted = NSImage(size: configured.size, flipped: false) { rect in
                    configured.draw(in: rect)
                    tint.set()
                    rect.fill(using: .sourceIn)
                    return true
                }
                tinted.draw(in: overlayRect)
            } else {
                configured.draw(in: overlayRect)
            }
        }
        out.unlockFocus()
        out.isTemplate = (tint == nil)
        return out
    }
}

#endif
