#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

extension WindowRenderer {
    /// Privacy (SPEC 3.9), drawn as the page, 900 pt wide: what is kept on
    /// Sam's Mac, for how long, what the side pictures use, the buttons and
    /// the activity; light and dark. From fixtures only: no audit log,
    /// retention file or usage file of the person's is read.
    static var privacyScenes: [Scene] {
        [
            PrivacyRenderScene.scene("nav-privacy"),
            PrivacyRenderScene.scene("nav-privacy-dark", dark: true),
        ]
    }
}

@MainActor
enum PrivacyRenderScene {
    static func scene(_ name: String, dark: Bool = false) -> WindowRenderer.Scene {
        .picture(name, size: CGSize(width: 900, height: 720), dark: dark) {
            page()
        }
    }

    static func page() -> AnyView {
        let now = PreviewUnderstandingReader.sampleNow
        let calendar = PreviewUnderstandingReader.sampleCalendar
        let activity = entries(now: now)
        let page = PrivacyDashboard(
            reader: PrivacyRenderReader(now: now), mutator: nil,
            retention: { .standard },
            picturesUsage: { PicturesUsage(sideBytes: 640_000_000, budgetBytes: 2_000_000_000, enabled: true) },
            activity: { activity }, now: { now }, calendar: calendar)
            .environment(\.forget, ForgetAction { _ in })
            .background(MCI.Color.background)
        return AnyView(page)
    }

    /// What Sam forgot and exported, as the audit log keeps it: counts and
    /// ranges, never content.
    static func entries(now: Date) -> [AuditEntry] {
        func at(_ hoursAgo: Double, _ action: AuditAction, _ details: [String: String]) -> AuditEntry {
            AuditEntry(timestamp: now.addingTimeInterval(-hoursAgo * 3_600), action: action, details: details,
                       rawLine: "\(action.rawValue)-\(hoursAgo)")
        }
        return [
            at(68.9, .deleteEventsInRange, ["range_minutes": "10", "count": "14"]),
            at(149.4, .deleteEvent, ["count": "1"]),
            at(243.4, .exportJson, ["events": "200"]),
        ]
    }
}

/// Sam's memory in counts and sizes only.
private struct PrivacyRenderReader: BrainReader {
    let now: Date

    func search(_ options: SearchOptions) async throws -> [Hit] { [] }
    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { [] }
    func recentEvents(limit: Int) async throws -> [Hit] { [] }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }

    func summaryStats() async throws -> SummaryStats {
        let nowUs = UInt64(now.timeIntervalSince1970 * 1_000_000)
        return SummaryStats(totalEvents: 41_208, oldestTsUs: nowUs - 37 * 86_400_000_000 - 3_600_000_000,
                            newestTsUs: nowUs, diskBytes: 0)
    }

    func storageUsage() async throws -> StorageUsage? {
        StorageUsage(database: StorageMeasurement(logicalBytes: 590_000_000, status: .complete),
                     wal: StorageMeasurement(logicalBytes: 20_000_000, status: .complete),
                     shm: StorageMeasurement(logicalBytes: 32_768, status: .complete),
                     managedBlobs: StorageMeasurement(logicalBytes: 1_400_000_000, status: .complete),
                     reportedTotalBytes: 2_010_032_768, complete: true)
    }
}
#endif
