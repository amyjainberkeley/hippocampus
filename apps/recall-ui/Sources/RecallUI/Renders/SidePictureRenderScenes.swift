#if DEBUG
import RecallUIKit
import SwiftUI

extension WindowRenderer {
    /// Pictures of windows beside the front one in History (SPEC 6.6),
    /// drawn with every other scene by `--render-window`, light and dark:
    ///
    /// - `history-side-pictures`: the afternoon with side windows pictured,
    ///   Slack's #launch open in the detail with its own picture.
    /// - `history-side-picture-masked`: Figma beside the editor, the part the
    ///   editor covered filled flat.
    /// - `history-side-thinned`: three days ago, where older pictures are
    ///   thinned to one per window per 15 minutes; a thinned moment shows its
    ///   app tile, its text and caption as before.
    static var sidePictureScenes: [Scene] {
        [
            sidePictureScene("history-side-pictures", select: SidePictureRenderFixture.slackId),
            sidePictureScene("history-side-pictures-dark", dark: true, select: SidePictureRenderFixture.slackId),
            sidePictureScene("history-side-picture-masked", select: SidePictureRenderFixture.figmaId),
            sidePictureScene("history-side-picture-masked-dark", dark: true,
                             select: SidePictureRenderFixture.figmaId),
            sidePictureScene("history-side-thinned", select: SidePictureRenderFixture.thinnedId, olderDay: true),
            sidePictureScene("history-side-thinned-dark", dark: true, select: SidePictureRenderFixture.thinnedId,
                             olderDay: true),
        ]
    }

    /// The window on History, read from `SidePictureRenderFixture`, with
    /// `id` open in the detail. Its pictures are opened before it draws, and
    /// their sealed files are gone before it does.
    private static func sidePictureScene(_ name: String, dark: Bool = false, select id: UInt64,
                                         olderDay: Bool = false) -> Scene {
        Scene.picture(name, size: CGSize(width: 1280, height: 860), dark: dark) {
            let base = NativePreviewReader(date: PreviewUnderstandingReader.sampleNow,
                                           now: PreviewUnderstandingReader.sampleNow,
                                           calendar: PreviewUnderstandingReader.sampleCalendar)
            let overviewMoments = OverviewPreviewBrainReader()
            let fixtures = RenderFixtureReader(base: base, overviewMoments: overviewMoments)
            guard let fixture = try? await SidePictureRenderFixture(base: fixtures, now: base.now) else {
                return AnyView(Color.clear)
            }
            fixture.remove()
            let now = base.now
            let calendar = base.calendar
            let reader = fixture.reader
            let understanding = PreviewUnderstandingReader(scenario: .populated)
            let model = AskViewModel(
                search: SearchViewModel(
                    reader: reader,
                    persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"],
                                                  store: KeepsNothing()),
                    userDictionaryLoader: { .empty }),
                history: TimelineViewModel(reader: reader, pageSize: 200,
                                           day: MemoryDay(date: olderDay ? fixture.thinnedDay : now,
                                                          calendar: calendar),
                                           now: { now }),
                understanding: understanding,
                calendar: calendar)
            await model.history.reload()
            if model.history.hits.contains(where: { $0.id == id }) {
                model.history.selectedHitId = id
                model.history.focusDetail()
            }
            let stamp = ISO8601DateFormatter().string(from: now)
            let receipt = try? CaptureHealthReceipt.decode(Data("""
                {"schema_version": 1, "updated_at": "\(stamp)", "last_stored_frame_at": "\(stamp)",
                 "stored_frame_count": 10, "stored_screenshot_count": 4}
                """.utf8))
            let overview = OverviewViewModel(understanding: understanding, selectedDate: now, calendar: calendar,
                                             healthLoader: { receipt }, now: { now },
                                             deletions: MemoryDeletionSignal(center: NotificationCenter()),
                                             savedBefore: { _ in throw UnderstandingError.unavailable })
            let you = UserModelViewModel(understanding: understanding, verdicts: VerdictInbox(directory: nil),
                                         deletions: MemoryDeletionSignal(center: NotificationCenter()))
            let thumbnails = OverviewPreviewThumbnails(windows: overviewMoments.windows)
            return AnyView(
                MemoryWorkspaceView(
                    reader: reader, understanding: understanding,
                    selection: .constant(.ask),
                    isSyntheticPreview: false,
                    healthLoader: { receipt },
                    contextExporter: { _ in "" },
                    calendar: calendar,
                    now: { now },
                    ask: model,
                    overview: overview,
                    you: you,
                    status: WindowStatus(kind: .remembering, title: NavigationCopy.remembering, action: .pause)
                )
                .environment(\.overviewThumbnails, thumbnails)
                .environment(\.screenshots, fixture.screenshots)
            )
        }
    }
}

/// Nothing typed is kept by a picture.
private final class KeepsNothing: KeyValueStore, Sendable {
    func data(forKey key: String) -> Data? { nil }
    func set(_ data: Data?, forKey key: String) {}
    func removeObject(forKey key: String) {}
}
#endif
