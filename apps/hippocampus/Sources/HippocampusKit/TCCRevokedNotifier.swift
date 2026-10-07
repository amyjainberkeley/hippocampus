// SPDX-License-Identifier: TBD-private
//
// TCCRevokedNotifier — cycle 8.45 audit risk #2 (TCC revoked mid-run).
// Surfaces the helper's `helper_health tcc_revoked=<surface>` signal
// as an actionable macOS user notification: "Hippocampus can't record
// because Screen Recording permission was revoked. Click to re-grant."
//
// This file lives in HippocampusKit (app-side, not helper-side) so:
//   (a) The notification is authored by the signed *app* bundle,
//       whose `UNUserNotificationCenter` is the right owner —
//       MCICaptureHelper is a background helper without a UI.
//   (b) The click action needs `NSWorkspace.shared.open(...)` which
//       only makes sense in the GUI process.
//
// Privacy invariant STRENGTHENED, never weakened: the notification
// body says which SURFACE was revoked (e.g. "Screen Recording") —
// never a file path, bundle id, window title, or captured pixel.
// Nothing user-content-derived reaches the notification center.
//
// This file uses `UserNotifications` (macOS 10.14+, satisfies the
// macOS 14+ deployment target). Test coverage exercises the pure
// content-assembly path via `TCCRevokedNotifierRequestBuilder`; the
// OS-touching `UNUserNotificationCenter` calls are behind a protocol
// seam so the delivery path is unit-testable without a real
// notification center.

import Foundation
import UserNotifications
#if canImport(AppKit)
    import AppKit
#endif

/// Protocol seam over `UNUserNotificationCenter` — the tiny slice we
/// use. Delivery + auth request are the OS boundary; the pure content
/// assembly lives in `TCCRevokedNotifierRequestBuilder` below.
public protocol UserNotificationCenter: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers ids: [String])
    func removeDeliveredNotifications(withIdentifiers ids: [String])
}

/// The real OS-side implementation. `// UNVERIFIED — needs live
/// macOS`.
public struct SystemUserNotificationCenter: UserNotificationCenter {
    public init() {}

    public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }

    public func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    public func removePendingNotificationRequests(withIdentifiers ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    public func removeDeliveredNotifications(withIdentifiers ids: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }
}

/// Pure request assembly — factored out so the content shape (title,
/// body, category, identifier, userInfo payload) is unit-testable
/// without a live notification center.
public enum TCCRevokedNotifierRequestBuilder {
    /// Notification category identifier. Registered once at first-
    /// notify by `TCCRevokedNotifier.registerCategoryIfNeeded()` so
    /// the "Open Settings" action button renders.
    public static let categoryIdentifier = "MCITCCRevoked"

    /// Action identifier for the click-through button.
    public static let openSettingsActionIdentifier = "MCITCCRevokedOpenSettings"

    /// Per-surface identifier so a duplicate revoke of the same
    /// surface replaces the old notification rather than stacking N
    /// copies. Distinct across surfaces so revoking BOTH Screen
    /// Recording AND Accessibility shows two notifications.
    public static func identifier(for reason: TCCRevokedReason) -> String {
        return "\(categoryIdentifier).\(reason.rawValue)"
    }

    /// userInfo payload key under which the settings-pane URL string
    /// travels. Read at click-action time by the notification-center
    /// delegate.
    public static let userInfoPaneKey = "MCITCCRevokedPaneURL"

    /// userInfo payload key under which the surface identifier
    /// travels — used for logging + tests, not the click action.
    public static let userInfoSurfaceKey = "MCITCCRevokedSurface"

    /// Assemble the `UNNotificationRequest` for a given revoke reason.
    public static func makeRequest(for reason: TCCRevokedReason) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reason.notificationTitle
        content.body = reason.notificationBody
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = [
            userInfoPaneKey: reason.settingsPaneURLString,
            userInfoSurfaceKey: reason.rawValue,
        ]
        // Persistent (no autodismiss timeout) — the notification is
        // actionable, the user MUST see it. Sound is deliberate: this
        // is a "your app is not doing its job" surface, not a passive
        // update.
        content.sound = .default

        // No trigger ⇒ deliver immediately.
        return UNNotificationRequest(
            identifier: identifier(for: reason),
            content: content,
            trigger: nil
        )
    }

    /// The category descriptor with the "Open Settings" action button.
    public static func makeCategory() -> UNNotificationCategory {
        let openSettings = UNNotificationAction(
            identifier: openSettingsActionIdentifier,
            title: "Open Settings",
            options: [.foreground]
        )
        return UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [openSettings],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }
}

/// The actor that owns the delivery lifecycle. Debounces
/// per-surface: while a revoke notification for surface X is
/// outstanding, further calls to `notifyRevoked(_:)` for X are
/// no-ops (the OS would suppress-and-replace anyway, but this saves
/// the syscall). `notifyRestored(_:)` clears the notification for X.
private final class TCCNotificationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

public actor TCCRevokedNotifier {
    private let center: UserNotificationCenter
    private var outstanding: [TCCRevokedReason: TCCNotificationObservation] = [:]
    private var authorization: Task<Void, Never>?

    public init(center: UserNotificationCenter = SystemUserNotificationCenter()) {
        self.center = center
    }

    /// Register the notification category (idempotent). Safe to call
    /// on every launch — subsequent calls replace the descriptor with
    /// itself. Only reachable via the AppKit build.
    public func registerCategory() async {
        #if canImport(AppKit)
            UNUserNotificationCenter.current().setNotificationCategories([
                TCCRevokedNotifierRequestBuilder.makeCategory()
            ])
        #endif
    }

    /// Emit (or re-emit) a persistent notification for the given
    /// revoked surface. Idempotent per surface — repeated calls are
    /// no-ops until `notifyRestored(_:)` clears the surface.
    ///
    /// Authorization is requested lazily on first notify. If the user
    /// denied notification authorization outright, the `add(_:)` call
    /// throws and we swallow the error — the menu-bar red pill is the
    /// belt to this suspenders, and the user chose the "no notifications"
    /// path deliberately.
    public func notifyRevoked(_ reason: TCCRevokedReason) async {
        guard !Task.isCancelled else { return }
        if let previous = outstanding[reason], !previous.isCancelled { return }
        let observation = TCCNotificationObservation()
        outstanding[reason] = observation
        await withTaskCancellationHandler {
            await deliver(reason, observation: observation)
        } onCancel: {
            // Synchronous cancellation lets a restarted watcher replace this
            // request even while the old task awaits the system auth sheet.
            observation.cancel()
        }
    }

    private func deliver(_ reason: TCCRevokedReason, observation: TCCNotificationObservation) async {
        if authorization == nil {
            let center = center
            authorization = Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
        }
        await authorization?.value
        guard outstanding[reason] === observation, !observation.isCancelled else {
            if outstanding[reason] === observation { outstanding.removeValue(forKey: reason) }
            return
        }

        let request = TCCRevokedNotifierRequestBuilder.makeRequest(for: reason)
        try? await center.add(request)
        if observation.isCancelled, outstanding[reason] === observation {
            outstanding.removeValue(forKey: reason)
        }
        // Never clear a newer observation of the same revoked surface.
        if outstanding[reason] == nil {
            let id = TCCRevokedNotifierRequestBuilder.identifier(for: reason)
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    /// Clear the notification for a surface that has been restored.
    /// Idempotent.
    public func notifyRestored(_ reason: TCCRevokedReason) {
        guard outstanding.removeValue(forKey: reason) != nil else { return }
        let id = TCCRevokedNotifierRequestBuilder.identifier(for: reason)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// Test-only accessor. Not public API surface — package-internal.
    internal func outstandingForTest() -> Set<TCCRevokedReason> {
        return Set(outstanding.filter { !$0.value.isCancelled }.keys)
    }
}

// MARK: - Click-action handler

/// The notification-center delegate glue. AppDelegate installs this
/// as `UNUserNotificationCenter.current().delegate` at boot so click
/// actions route through `handleActionResponse`, which opens the
/// System Settings pane the notification carries in its userInfo.
public enum TCCRevokedNotificationActionHandler {
    /// Handle a `UNNotificationResponse`. Returns `true` if the
    /// response was ours (either the explicit "Open Settings"
    /// action or a default-tap on a MCITCCRevoked notification);
    /// `false` if it belongs to some other category and should be
    /// passed to the caller's other handlers.
    @discardableResult
    public static func handle(_ response: UNNotificationResponse) -> Bool {
        let content = response.notification.request.content
        guard content.categoryIdentifier == TCCRevokedNotifierRequestBuilder.categoryIdentifier
        else { return false }

        // Both the explicit "Open Settings" action and a default tap
        // on the notification body should open the pane — the user's
        // intent is the same either way.
        let isOurAction =
            response.actionIdentifier == TCCRevokedNotifierRequestBuilder.openSettingsActionIdentifier
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier

        guard isOurAction,
              let urlString = content.userInfo[
                TCCRevokedNotifierRequestBuilder.userInfoPaneKey
              ] as? String,
              let url = URL(string: urlString)
        else { return true }

        #if canImport(AppKit)
            NSWorkspace.shared.open(url)
        #endif
        return true
    }
}
