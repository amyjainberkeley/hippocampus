// SPDX-License-Identifier: TBD-private
//
// What remembering is doing, for the menu-bar icon, the menu, Ask's footer
// and Preferences (spec-shell S2 and S4, RULINGS S and B1). Only the agent's
// durable receipt can establish that memory was saved.

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Remembering's status, derived from what the person asked for and what was
/// committed to storage. A running process or a helper delivery counter never
/// proves saved memory.
public enum MenuBarStatus: Equatable, Sendable {
    case idle
    case starting
    case recording
    case paused
    case error(reason: String)
    case needsPermission(TCCRevokedReason)
    /// Remembering is failing. `reason` is the receipt's code.
    case blocked(reason: String)
    case stale(reason: String)
    case noMemory
    case unchanged
    /// A window was skipped for privacy. `reason` is the receipt's code.
    case skipping(reason: String)
    /// The person asked it to stop, pause or turn off, and that failed, so
    /// it may still be reading the screen (product critique 3).
    case stopFailed(reason: String)

    /// A start may take this long before missing evidence counts as a fault
    /// (spec-shell S4, RULINGS S6).
    public static let startingGrace: TimeInterval = 45
    /// "Skipping this window" waits until the same skip has held this long
    /// with no newer save (RULINGS S8).
    public static let skipHold: TimeInterval = 10

    /// Line 1 of the menu.
    public var displayText: String {
        switch self {
        case .recording, .unchanged: return "Remembering"
        case .starting: return "Starting…"
        case .noMemory: return "Nothing saved yet"
        case .skipping: return "Skipping this window"
        case .paused: return "Paused"
        case .idle: return "Off"
        case .needsPermission: return "Needs permission"
        case .blocked, .stale, .error: return "Not saving"
        case .stopFailed: return "Couldn’t stop"
        }
    }

    /// Line 2, when the status alone says why. "Last saved", "Since" and
    /// "You stopped it" need times, so `StatusRow` adds them.
    public var detailText: String? {
        switch self {
        case .idle, .starting, .recording, .unchanged, .paused, .noMemory: return nil
        case .skipping(let code): return ReceiptCode.skipText(code)
        case .needsPermission(let permission): return "\(permission.name) is off for Hippocampus."
        case .blocked(let code): return ReceiptCode.failureText(code)
        case .stale: return "It can’t confirm anything was saved."
        case .error: return "It stopped and couldn’t start again."
        case .stopFailed: return "Hippocampus may still be reading the screen."
        }
    }

    /// The one button that goes with the status once setup is done. Each
    /// acts in the state it is shown for (product critique 3 and 11).
    public var action: CaptureStatusAction? {
        switch self {
        case .recording, .unchanged, .starting, .noMemory, .skipping: return .pause
        case .paused: return .resume
        case .idle: return .turnOn
        case .needsPermission(let permission): return .openSystemSettings(permission)
        case .blocked, .stale, .error: return .tryAgain
        case .stopFailed: return .quit
        }
    }

    /// Remembering as it should, with nothing to report.
    public var isRemembering: Bool { self == .recording || self == .unchanged }

    /// Menu-bar status is static, including while saving memory.
    public var shouldPulse: Bool { false }

    /// A failed stop and an explicit off or pause come first; permission and
    /// storage failures then take precedence over evidence of earlier saves.
    /// `stopping` is a turn-off still under way: the setting is already off,
    /// but the screen may be read until the stop is done.
    public static func derive(
        from state: SupervisorState,
        captureEnabled: Bool = true,
        integrityError: String? = nil,
        tccRevokedSurface: TCCRevokedReason? = nil,
        receipt: CaptureStatusReceipt? = nil,
        helperHealth: HealthSnapshot? = nil,
        captureStartedAt: Date? = nil,
        stopFailed: Bool = false,
        stopping: Bool = false,
        skipSeenSince: Date? = nil,
        now: Date = Date()
    ) -> MenuBarStatus {
        // A failed shutdown is not proof of being off. Keep that failure visible
        // even after the requested setting has correctly been latched false.
        if case .crashed(let reason) = state {
            if stopFailed { return .stopFailed(reason: reason) }
            // A permission turned off during a start: say which, so the fix
            // is in reach (spec-shell S4.2).
            if captureEnabled, let surface = tccRevokedSurface { return .needsPermission(surface) }
            return .error(reason: reason)
        }
        // Off shows once the stop is done, never before: the icon may
        // overstate, never understate (RULINGS B1 and S7).
        guard captureEnabled || stopping else { return .idle }
        if state == .paused { return .paused }
        if let reason = tccRevokedSurface {
            return .needsPermission(reason)
        }
        if let reason = integrityError {
            return .error(reason: reason)
        }
        if state == .starting { return .starting }
        guard state == .running else { return .idle }
        // Every start clears the receipt, and the helper's first heartbeat
        // takes about 30 s: a young run is starting, not failing.
        let young = captureStartedAt.map { (0..<startingGrace).contains(now.timeIntervalSince($0)) } ?? false
        func notConfirmed(_ why: String) -> MenuBarStatus { young ? .starting : .stale(reason: why) }
        guard let receipt else {
            return notConfirmed("The status receipt is missing or unreadable.")
        }
        guard isFresh(receipt.updatedAt, now: now),
              captureStartedAt.map({ receipt.updatedAt >= $0 }) ?? true else {
            return notConfirmed("The status receipt is older than this run.")
        }
        if let code = receipt.blockedReason {
            switch ReceiptCode(code) {
            case .permission(let permission): return .needsPermission(permission)
            case .failure: return .blocked(reason: code)
            case .skip, .unchanged, .fastSwitch: break
            }
        }
        // The receipt's skip is the last one since the last save, from any
        // window, so it shows only once it has held (RULINGS S8).
        let held = skipSeenSince.map { now.timeIntervalSince($0) >= skipHold } ?? false
        for code in [receipt.blockedReason, receipt.suppressionReason].compactMap({ $0 }) {
            switch ReceiptCode(code) {
            case .permission(let permission): return .needsPermission(permission)
            case .unchanged: if receipt.storedFrameCount == 0 { return .noMemory }
            case .skip: if held { return .skipping(reason: code) }
            case .failure: if held { return .blocked(reason: code) }
            case .fastSwitch: break
            }
        }
        guard receipt.storedFrameCount > 0, let saved = receipt.lastStoredFrameAt else {
            return .noMemory
        }
        // Storage heartbeat is not capture activity. A new run must save its own
        // frame before showing saving status; static-screen dedup stays neutral.
        if captureStartedAt.map({ saved >= $0 }) ?? false,
           now.timeIntervalSince(saved) >= 0,
           now.timeIntervalSince(saved) <= 600 {
            return .recording
        }
        if let helperHealth, isFresh(helperHealth.lastUpdated, now: now),
           captureStartedAt.map({ helperHealth.lastUpdated >= $0 }) ?? false {
            return .unchanged
        }
        return notConfirmed("No recent saved frame or capture heartbeat.")
    }

    private static func isFresh(_ date: Date, now: Date) -> Bool {
        (0...120).contains(now.timeIntervalSince(date))
    }
}

/// What a receipt code means (spec-shell S2 with product critique 10). Codes
/// are content-free; one this app does not know is a failure it cannot name.
enum ReceiptCode: Equatable {
    case permission(TCCRevokedReason)
    /// The screen did not change: nothing is wrong.
    case unchanged
    /// The window changed too quickly to read. It stays "Remembering", so a
    /// fast switch never flickers the menu (product critique 10).
    case fastSwitch
    /// Skipped for privacy. Whole-screen reading goes on for every skip but
    /// a password field (critique-shell-engineering 4).
    case skip
    case failure

    init(_ code: String) {
        switch code {
        case "screen_recording_permission": self = .permission(.screenRecording)
        case "accessibility_permission": self = .permission(.accessibility)
        case "unchanged_screen", "deduplicated": self = .unchanged
        case "focus-race-dropped": self = .fastSwitch
        case _ where Self.skipText(code) != nil: self = .skip
        default: self = .failure
        }
    }

    /// While a password field is active nothing at all is read, so this is
    /// the one skip the hollow dot stands for (RULINGS B1).
    static let passwordField: Set<String> = ["secure_input", "secure-event-input"]

    static func skipText(_ code: String) -> String? {
        switch code {
        case "app_denied", "denylist-source", "denylist-postcapture": return "This window is never read."
        case "secure_input", "secure-event-input", "ax-secure-subrole": return "A password field is active."
        case "os-blacked-region": return "macOS protects this window."
        case "ocr-time-secret": return "It saw what looks like a password or key, so it saved nothing."
        case "failsafe-unknown": return "It couldn’t tell if this window is private, so it skipped it."
        case "private_browsing": return "This is a private window."
        case "browser_window_unknown": return "It can’t tell if this browser window is private."
        case "app_identity_unknown": return "It can’t tell which app this is."
        default: return nil
        }
    }

    static func failureText(_ code: String) -> String {
        switch code {
        case "storage_error", "store_unavailable", "ingest_failed", "activity_ingest_failed":
            return "It can’t save. Check free disk space."
        case "helper_disconnected": return "It lost its view of the screen."
        case "capture_failed": return "It couldn’t read the screen."
        case "capture_disabled": return "It didn’t start properly."
        default: return "It stopped and can’t say why."
        }
    }
}

/// When the receipt's skip was first seen with no newer save, so "Skipping
/// this window" waits until the same skip has held for about 10 s (RULINGS
/// S8). The supervisor updates it each time it reads the receipt.
public struct SkipWatch: Equatable, Sendable {
    private var codes: [String?] = []
    private var lastSaved: Date?
    /// When the current skip was first seen; nil when there is none.
    public private(set) var since: Date?

    public init() {}

    public mutating func observe(_ receipt: CaptureStatusReceipt?, at now: Date) {
        guard let receipt, receipt.suppressionReason != nil || receipt.blockedReason != nil else {
            self = SkipWatch()
            return
        }
        let codes = [receipt.blockedReason, receipt.suppressionReason]
        if codes == self.codes, receipt.lastStoredFrameAt == lastSaved, since != nil { return }
        self.codes = codes
        lastSaved = receipt.lastStoredFrameAt
        since = now
    }
}

// MARK: - TCC revoked reason (cycle 8.45 audit risk #2)

/// A permission macOS can turn off for Hippocampus. Kept as an enum (rather
/// than plain strings) so the surface identity round-trips through the app:
/// the notification click-action deep-links to the correct System Settings
/// pane per `settingsPaneURLString` below.
public enum TCCRevokedReason: String, Sendable, Equatable, CaseIterable {
    case screenRecording
    case accessibility
    case fullDiskAccess
    case automation

    /// The permission's name, as macOS spells it.
    public var name: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .fullDiskAccess: return "Full Disk Access"
        case .automation: return "Automation"
        }
    }

    /// Title of the notification shown when a permission is turned off.
    public var notificationTitle: String {
        return "Hippocampus stopped remembering"
    }

    /// Body of that notification: what happened, then what the click does
    /// (product critique 9).
    public var notificationBody: String {
        "\(name) was turned off for Hippocampus. Click to open System Settings."
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

// MARK: - Picture

extension MenuBarStatus {
    /// The picture the menu bar shows (RULINGS B1). It may overstate, never
    /// understate: every skip but a password field keeps the solid dot,
    /// because the rest of the screen is still read; a stop that failed
    /// keeps it, because it may still be reading; and the 45 s grace keeps
    /// a start from showing h!. Only a password field, which stops all
    /// reading, shows the hollow dot.
    public var markState: HiMark.State {
        switch self {
        case .recording, .unchanged, .starting, .noMemory, .stopFailed: return .remembering
        case .skipping(let code): return ReceiptCode.passwordField.contains(code) ? .skipping : .remembering
        case .paused, .idle: return .off
        case .needsPermission, .error, .blocked, .stale: return .needsYou
        }
    }
}

// MARK: - NSImage factory

#if canImport(AppKit)

/// Draws the four `HiMark` pictures once each, for the status item,
/// Preferences and the tests. Every picture is a single-color template that
/// macOS tints for light and dark bars, so state lives in shape, not color.
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

    /// One picture on its own, for tests and previews. The menu bar always
    /// goes through a status, so the icon follows the supervisor's state.
    static func image(for state: HiMark.State) -> NSImage {
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
