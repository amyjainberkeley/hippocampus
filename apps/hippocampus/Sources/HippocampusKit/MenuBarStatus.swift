// SPDX-License-Identifier: TBD-private
//
// Local capture status for the menu-bar icon and Preferences.
// Only the agent's durable receipt can establish that memory was saved.

import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Capture status derived from user intent and committed storage evidence.
/// A running process or helper delivery counter never proves saved memory.
public enum MenuBarStatus: Equatable, Sendable {
    case idle
    case starting
    case recording
    case paused
    case error(reason: String)
    case needsPermission(TCCRevokedReason)
    case blocked(reason: String)
    case stale(reason: String)
    case noMemory
    case unchanged

    /// Short label rendered in the drop-down header row + used in
    /// tests to check state distinctness.
    public var displayText: String {
        switch self {
        case .idle: return "Off"
        case .starting: return "Starting capture"
        case .recording: return "Saving memory"
        case .paused: return "Paused"
        case .error: return "Error"
        case .needsPermission: return "Needs permission"
        case .blocked: return "Blocked"
        case .stale: return "Status unavailable"
        case .noMemory: return "No saved memory yet"
        case .unchanged: return "No recent changes"
        }
    }

    /// The dot color to render next to the header row text. Color stays
    /// inside the menu; the menu-bar icon is a single-color template.
    public var indicatorColor: Color {
        switch self {
        case .idle, .starting, .unchanged: return .secondary
        case .recording: return .green
        case .paused: return .yellow
        case .error: return .red
        case .needsPermission, .blocked, .stale, .noMemory: return .orange
        }
    }

    /// Menu-bar status is static, including while saving memory.
    public var shouldPulse: Bool { false }

    /// Explicit off/pause wins; permission and storage failures then take
    /// precedence over evidence of previous successful saves.
    public static func derive(
        from state: SupervisorState,
        captureEnabled: Bool = true,
        integrityError: String? = nil,
        tccRevokedSurface: TCCRevokedReason? = nil,
        receipt: CaptureStatusReceipt? = nil,
        helperHealth: HealthSnapshot? = nil,
        captureStartedAt: Date? = nil,
        now: Date = Date()
    ) -> MenuBarStatus {
        // A failed shutdown is not proof of being off. Keep that failure visible
        // even after the requested setting has correctly been latched false.
        if case .crashed(let reason) = state {
            return .error(reason: reason)
        }
        guard captureEnabled else { return .idle }
        if state == .paused { return .paused }
        if let reason = tccRevokedSurface {
            return .needsPermission(reason)
        }
        if let reason = integrityError {
            return .error(reason: reason)
        }
        if state == .starting { return .starting }
        guard state == .running else { return .idle }
        guard let receipt else {
            return .stale(reason: "Saved memory could not be verified. The capture status is missing or unreadable.")
        }
        guard isFresh(receipt.updatedAt, now: now),
              captureStartedAt.map({ receipt.updatedAt >= $0 }) ?? true else {
            return .stale(reason: "Capture status is out of date. Saved counts below are from the last report.")
        }
        if let code = receipt.blockedReason ?? receipt.suppressionReason {
            switch code {
            case "screen_recording_permission": return .needsPermission(.screenRecording)
            case "accessibility_permission": return .needsPermission(.accessibility)
            case "unchanged_screen", "deduplicated":
                if receipt.storedFrameCount == 0 { return .noMemory }
            default: return .blocked(reason: suppressionText(code))
            }
        }
        guard receipt.storedFrameCount > 0, let saved = receipt.lastStoredFrameAt else {
            return .noMemory
        }
        // Storage heartbeat is not capture activity. A new run must save its own
        // frame before showing saving status; static-screen dedup stays neutral.
        if captureStartedAt.map({ saved >= $0 }) ?? false,
           now.timeIntervalSince(saved) >= 0,
           now.timeIntervalSince(saved) <= 600,
           receipt.suppressionReason == nil {
            return .recording
        }
        if let helperHealth, isFresh(helperHealth.lastUpdated, now: now),
           captureStartedAt.map({ helperHealth.lastUpdated >= $0 }) ?? false {
            return .unchanged
        }
        return .stale(reason: "No recent saved frame or capture heartbeat. Check capture settings and logs.")
    }

    private static func isFresh(_ date: Date, now: Date) -> Bool {
        (0...120).contains(now.timeIntervalSince(date))
    }

    private static func suppressionText(_ code: String) -> String {
        switch code {
        case "app_denied", "denylist-source", "denylist-postcapture": return "The current source is excluded by your privacy settings."
        case "secure_input", "secure-event-input", "ax-secure-subrole": return "Secure input is active. Capture will resume when it ends."
        case "os-blacked-region": return "macOS protected the current screen region from capture."
        case "ocr-time-secret": return "Sensitive content was filtered before it could be saved."
        case "failsafe-unknown": return "The current content could not be checked for privacy. Switch to another window."
        case "focus-race-dropped": return "The active window changed during capture. Waiting for a stable window."
        case "private_browsing": return "Private browsing is excluded from capture."
        case "browser_window_unknown": return "The browser window's privacy mode could not be verified. Switch to a supported normal window."
        case "app_identity_unknown": return "The current app could not be identified. Switch to an identifiable app."
        case "storage_error", "store_unavailable", "ingest_failed": return "Memory could not be saved. Check available disk space and capture logs."
        case "helper_disconnected": return "The screen capture helper disconnected. Restart capture and check the logs."
        case "capture_failed": return "Screen capture failed. Check permissions and capture logs."
        case "capture_disabled": return "The capture service reports that capture is disabled. Review capture settings."
        default: return "Capture was blocked for an unrecognized reason. Review capture settings and logs."
        }
    }

    public var detailText: String {
        switch self {
        case .idle: return "Capture is off or has not started."
        case .starting: return "Starting the capture service. Waiting for saved memory to be verified."
        case .recording: return "A recent frame was saved to memory."
        case .paused: return "Capture is paused. Existing memories remain available."
        case .error(let reason), .blocked(let reason), .stale(let reason): return reason
        case .needsPermission(let permission):
            switch permission {
            case .screenRecording: return "Screen Recording permission is required to capture the screen."
            case .accessibility: return "Accessibility permission is required to inspect screen content safely."
            case .fullDiskAccess: return "Full Disk Access permission is required."
            case .automation: return "Automation permission is required."
            }
        case .noMemory: return "No captured frames have been saved to memory."
        case .unchanged: return "Capture is responding. No new frame has been saved recently."
        }
    }

    public var action: CaptureStatusAction? {
        switch self {
        case .idle: return .start
        case .paused: return .resume
        case .needsPermission(let permission): return .openPermission(permission)
        case .error: return .openLogs
        case .blocked, .stale, .noMemory: return .reviewCapture
        case .starting, .recording, .unchanged: return nil
        }
    }
}

/// The capture command visible in the status menu. The agent can be
/// healthy while screen capture is disabled, so topology state alone
/// cannot decide whether Start or Stop Recording is appropriate.
public enum RecordingControl: Equatable, Sendable {
    case none
    case start
    case stop

    public static func derive(
        from state: SupervisorState,
        captureEnabled: Bool
    ) -> RecordingControl {
        if state == .starting { return .none }
        if captureEnabled && state.isActive { return .stop }
        return .start
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

/// A static label for MenuBarExtra. Animating its opacity repeatedly updates
/// the AppKit status button and layout; no clock or animation belongs here.
public struct MenuBarStatusLabel: View {
    public let status: MenuBarStatus

    public init(status: MenuBarStatus) {
        self.status = status
    }

    public var body: some View {
        iconImage
            .accessibilityLabel("Hippocampus — \(status.displayText)")
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

// MARK: - Picture

extension MenuBarStatus {
    /// The picture the menu bar shows. Any state in which the screen may be
    /// read shows the solid dot: the icon may overstate, never understate.
    public var markState: HiMark.State {
        switch self {
        case .recording, .unchanged, .starting, .noMemory: return .remembering
        case .paused, .idle: return .off
        case .needsPermission, .error, .blocked, .stale: return .needsYou
        }
    }
}

// MARK: - NSImage factory

#if canImport(AppKit)

/// Draws the four `HiMark` pictures once each, for `MenuBarStatusLabel`
/// and the tests. Every picture is a single-color template that macOS
/// tints for light and dark bars, so state lives in shape, not color.
@MainActor
public enum MenuBarStatusIcon {

    /// Canonical NSStatusItem size on macOS 14+.
    static let baseSize = NSSize(width: 22, height: 22)
    /// One bitmap per display scale: 22, 44 and 66 px.
    static let scales: [CGFloat] = [1, 2, 3]

    // Fixed, reason-independent cache: repeated health updates must not
    // draw or allocate another image for the same picture.
    private static let remembering = render(.remembering)
    private static let skipping = render(.skipping)
    private static let off = render(.off)
    private static let needsYou = render(.needsYou)

    public static func image(for status: MenuBarStatus) -> NSImage {
        image(for: status.markState)
    }

    public static func image(for state: HiMark.State) -> NSImage {
        switch state {
        case .remembering: return remembering
        case .skipping: return skipping
        case .off: return off
        case .needsYou: return needsYou
        }
    }

    private static func render(_ state: HiMark.State) -> NSImage {
        let image = NSImage(size: baseSize)
        for scale in scales {
            guard let bitmap = bitmap(state, scale: scale) else { continue }
            let rep = NSBitmapImageRep(cgImage: bitmap)
            rep.size = baseSize
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }

    /// One bitmap in its own sRGB context, y growing downward. Stems are
    /// 2 pt, so the h is 8 pt wide and the letters 12.9 pt tall; the h stem
    /// starts 5 pt from the left and the baseline sits 4.5 pt up. The h
    /// stem's left edge, the i's left edge, the baseline and the dot's
    /// center are snapped to this bitmap's pixels, so stems stay sharp at 1x.
    static func bitmap(_ state: HiMark.State, scale: CGFloat) -> CGImage? {
        let side = Int(baseSize.width * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)

        let unit = 2 / HiMark.stemWidth * scale
        let hLeft = (5 * scale).rounded()
        let baseline = (17.5 * scale).rounded()
        let top = baseline - HiMark.baseline * unit
        let iLeft = (hLeft + HiMark.iStemLeft * unit).rounded()
        let dotX = iLeft + HiMark.stemWidth / 2 * unit
        // A dot centered on the i shares the i's pixel phase.
        let phase = dotX - dotX.rounded(.down)
        func snapped(_ y: CGFloat) -> CGFloat { (y - phase).rounded() + phase }
        let dotY = snapped(top + HiMark.dotCenter.y * unit)
        let dotRadius = HiMark.dotRadius * unit

        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: HiMark.letterStrength(for: state)))
        for part in HiMark.parts(for: state) {
            switch part {
            case .h:
                context.addPath(placed(HiMark.hOnly(), x: hLeft, y: top, unit: unit))
                context.fillPath(using: .winding)
            case .iStem, .bangStem:
                let stem = part == .iStem ? HiMark.iStem() : HiMark.bangStem()
                context.addPath(placed(stem, x: iLeft - HiMark.iStemLeft * unit, y: top, unit: unit))
                context.fillPath(using: .winding)
            case .dot:
                context.fillEllipse(in: square(x: dotX, y: dotY, radius: dotRadius))
            case .bangDot:
                context.fillEllipse(in: square(x: dotX, y: snapped(top + HiMark.bangDotCenter.y * unit), radius: dotRadius))
            case .ring:
                // Whole-pixel radii keep the hole open at 1x. The ring
                // rests where the solid dot does.
                let outer = (HiMark.ringOuterRadius * unit).rounded()
                let inner = (HiMark.ringInnerRadius * unit).rounded()
                let y = snapped(dotY + dotRadius - outer)
                context.addEllipse(in: square(x: dotX, y: y, radius: outer))
                context.addEllipse(in: square(x: dotX, y: y, radius: inner))
                context.fillPath(using: .evenOdd)
            }
        }
        return context.makeImage()
    }

    private static func placed(_ path: CGPath, x: CGFloat, y: CGFloat, unit: CGFloat) -> CGPath {
        var transform = CGAffineTransform(translationX: x, y: y).scaledBy(x: unit, y: unit)
        return path.copy(using: &transform) ?? path
    }

    private static func square(x: CGFloat, y: CGFloat, radius: CGFloat) -> CGRect {
        CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)
    }
}

#endif
