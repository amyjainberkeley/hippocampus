// SPDX-License-Identifier: TBD-private
//
// BriefNotificationController.swift — first-brief notification logic
// for Hippocampus.app per `docs/design/brief-viewer-spec.md` §"When the
// user discovers their first brief".
//
// Behavior contract (spec §"When the user discovers their first brief"):
//
//   1. First brief ever generated AND notifications not yet asked →
//      request UNUserNotificationCenter authorization (polite, once).
//   2. If granted, fire a single notification: "Your first Hippocampus
//      brief is ready." with deep-link payload `hippocampus://recall?tab=brief`.
//   3. Set the fire-once UserDefaults flag so subsequent days are silent.
//   4. Optional setting: `MCIBriefNotifyEachMorning` → fire on every
//      new brief day (off by default; opt-in via Hippocampus.app preferences).
//
// This file is the protocol surface + the production controller. Tests
// inject a `NotificationCenterClient` fake so the fire-once invariant is
// pinned without touching the real `UNUserNotificationCenter`.

import Foundation
import UserNotifications
import os

/// Test seam over `UNUserNotificationCenter`. The production
/// implementation forwards to the real center; tests replace it with a
/// fake that records calls and lets the test set the authorization
/// state directly.
public protocol NotificationCenterClient: AnyObject, Sendable {
    /// Current authorization status. `nil` until first probe.
    func currentAuthorizationStatus() async -> UNAuthorizationStatus
    /// Request authorization with the alert + sound options. Returns
    /// whether the user granted (or had already granted) permission.
    func requestAuthorization() async throws -> Bool
    /// Add a notification request. Returns whether scheduling succeeded.
    func add(_ request: UNNotificationRequest) async throws
}

/// Production adapter — forwards to `UNUserNotificationCenter.current()`.
public final class SystemNotificationCenterClient: NotificationCenterClient, @unchecked Sendable {
    public init() {}

    public func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    public func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    public func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
}

/// Storage seam over `UserDefaults` so tests can inject an in-memory dict.
public protocol BriefDefaultsStore: AnyObject {
    func bool(forKey: String) -> Bool
    func set(_ value: Bool, forKey: String)
}

extension UserDefaults: BriefDefaultsStore {}

/// First-brief notification controller.
///
/// One method does the work: `checkAndMaybeFireFirstBriefNotification(briefExists:)`.
/// Hippocampus.app calls this on launch + on any change to brief presence
/// (e.g. when the agent process pings that it wrote a new brief). The
/// controller decides whether to ask + fire based on the fire-once flag.
public actor BriefNotificationController {
    /// UserDefaults key flipped to `true` once the first-brief notification
    /// has fired. Bumping the key forces the notification to re-fire (used
    /// only by tests).
    public static let firstFiredKey = "MCIBriefFirstNotificationFired"

    /// Opt-in: notify on every new-brief day. Off by default per spec.
    public static let notifyEachMorningKey = "MCIBriefNotifyEachMorning"

    /// Tracks the last date_local we notified for (only meaningful when
    /// `notifyEachMorningKey` is on). Stored under this key in
    /// UserDefaults as a String.
    public static let lastNotifiedDateKey = "MCIBriefLastNotifiedDate"

    /// Notification identifier — single id so a repeat fire would replace
    /// rather than stack.
    public static let firstBriefNotificationId = "ai.hippocampus.brief.first"

    private let notifications: NotificationCenterClient
    private let defaults: BriefDefaultsStore
    private let logger = Logger(subsystem: "ai.hippocampus", category: "brief-notification")

    public init(
        notifications: NotificationCenterClient = SystemNotificationCenterClient(),
        defaults: BriefDefaultsStore = UserDefaults.standard
    ) {
        self.notifications = notifications
        self.defaults = defaults
    }

    /// Decision result for one check call. Exposed for test assertions.
    public enum Outcome: Equatable, Sendable {
        /// `briefExists` was false — nothing to notify about.
        case noBriefYet
        /// The first-brief notification has already fired — silent.
        case alreadyFired
        /// User has not granted notification permission — silent. (We
        /// only ask the system once per check; the system itself caps
        /// further re-prompts.)
        case permissionDenied
        /// Asked for permission and the user declined — silent.
        case permissionAskedAndDeclined
        /// Fired the first-brief notification successfully.
        case firedFirstBrief
        /// "Notify each morning" is on AND today's date hasn't been
        /// notified yet — fired a per-morning notification.
        case firedPerMorning(dateLocal: String)
    }

    /// Top-level entry point. `briefExists` is the caller's signal that
    /// at least one brief is present in the store. `latestBriefDate` is
    /// the most-recent brief's `date_local` — used for per-morning mode.
    @discardableResult
    public func checkAndMaybeFireFirstBriefNotification(
        briefExists: Bool,
        latestBriefDate: String? = nil
    ) async -> Outcome {
        guard briefExists else {
            return .noBriefYet
        }

        let firstAlreadyFired = defaults.bool(forKey: Self.firstFiredKey)
        let notifyEachMorning = defaults.bool(forKey: Self.notifyEachMorningKey)

        // First-brief path — ask once.
        if !firstAlreadyFired {
            let status = await notifications.currentAuthorizationStatus()
            switch status {
            case .notDetermined:
                let granted = (try? await notifications.requestAuthorization()) ?? false
                if !granted {
                    logger.info("brief-notification: user declined permission")
                    return .permissionAskedAndDeclined
                }
            case .denied:
                return .permissionDenied
            case .authorized, .provisional, .ephemeral:
                break
            @unknown default:
                return .permissionDenied
            }

            let req = Self.makeFirstBriefRequest()
            do {
                try await notifications.add(req)
                defaults.set(true, forKey: Self.firstFiredKey)
                logger.info("brief-notification: fired first-brief notification")
                return .firedFirstBrief
            } catch {
                logger.error("brief-notification: add failed: \(error.localizedDescription)")
                return .permissionDenied
            }
        }

        // Per-morning path — only when explicitly opted in.
        if notifyEachMorning, let date = latestBriefDate {
            let lastNotified = (defaults as? UserDefaults)?.string(forKey: Self.lastNotifiedDateKey) ?? ""
            if lastNotified == date {
                return .alreadyFired
            }
            let status = await notifications.currentAuthorizationStatus()
            switch status {
            case .authorized, .provisional, .ephemeral:
                let req = Self.makePerMorningRequest(dateLocal: date)
                do {
                    try await notifications.add(req)
                    (defaults as? UserDefaults)?.set(date, forKey: Self.lastNotifiedDateKey)
                    return .firedPerMorning(dateLocal: date)
                } catch {
                    logger.error("brief-notification: per-morning add failed: \(error.localizedDescription)")
                    return .permissionDenied
                }
            default:
                return .permissionDenied
            }
        }

        return .alreadyFired
    }

    /// First-brief notification body — spec copy.
    public static func makeFirstBriefRequest() -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Your first Hippocampus brief is ready"
        content.body = "Open Recall to read a one-screen summary of yesterday."
        content.sound = .default
        content.userInfo = [
            "deepLink": "hippocampus://recall?tab=brief",
        ]
        return UNNotificationRequest(
            identifier: firstBriefNotificationId,
            content: content,
            trigger: nil  // immediate
        )
    }

    /// Per-morning ("notify each morning" opt-in) notification body.
    public static func makePerMorningRequest(dateLocal: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Your Hippocampus brief is ready"
        content.body = "Your summary for \(dateLocal) is ready in Recall."
        content.sound = .default
        content.userInfo = [
            "deepLink": "hippocampus://recall?tab=brief",
            "dateLocal": dateLocal,
        ]
        return UNNotificationRequest(
            identifier: "\(firstBriefNotificationId).morning.\(dateLocal)",
            content: content,
            trigger: nil
        )
    }
}
