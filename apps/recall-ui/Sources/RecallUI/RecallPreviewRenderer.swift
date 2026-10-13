#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

/// `recall-ui --synthetic-preview --render-previews=<dir>` draws Overview and
/// You in every state to PNG files from fixtures, then ends the process
/// (spec-recall S7 as amended by critique-recall-engineering finding 17).
///
/// Nothing reaches the screen or the person's data: the app is made unable
/// to activate before anything else runs, each view is hosted in a window
/// that is never ordered on screen, every reader is a fixture
/// (`OverviewPreviewUnderstanding`, `OverviewPreviewBrainReader`), verdicts go
/// to a temporary folder, and the clock, time zone, locale and appearance are
/// fixed. The models are read before drawing, and drawing waits until the
/// screenshots have stopped arriving rather than for a fixed time. Each image
/// is drawn into a bitmap allocated at twice the view's size.
@MainActor
enum RecallPreviewRenderer {
    static let flag = "--render-previews="

    /// The folder asked for, only together with `--synthetic-preview`.
    static func directory(arguments: [String]) -> URL? {
        guard arguments.contains("--synthetic-preview"),
              let argument = arguments.first(where: { $0.hasPrefix(flag) })
        else { return nil }
        let path = String(argument.dropFirst(flag.count))
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Draws every state and exits when the arguments ask for it; returns at
    /// once otherwise. Call it before any scene, window, menu-bar item or
    /// activation exists.
    static func renderAndExitIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let directory = directory(arguments: arguments) else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let progress = Progress()
        Task { @MainActor in
            do {
                _ = try await renderAll(to: directory)
            } catch {
                progress.failed = true
            }
            progress.done = true
        }
        while !progress.done {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        exit(progress.failed ? 1 : 0)
    }

    @MainActor
    private final class Progress {
        var done = false
        var failed = false
    }

    static let width: CGFloat = 900
    static let firstScreen: CGFloat = 720

    /// Every state, as `overview-*.png` and `you-*.png` in `directory`.
    static func renderAll(to directory: URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let brain = OverviewPreviewBrainReader()
        let thumbnails = OverviewPreviewThumbnails(windows: brain.windows)
        let verdicts = try temporaryVerdicts()
        var written: [URL] = []

        func overview(_ name: String, _ state: OverviewPreviewUnderstanding.State, height: CGFloat = 1_250,
                      today: Bool = true, dark: Bool = false, select: Int64? = nil,
                      hover: StripHover? = nil, noticedOpen: Bool = false, showSearches: Bool = false) async throws {
            let now = today ? PreviewUnderstandingReader.sampleNow
                : PreviewUnderstandingReader.sampleNow.addingTimeInterval(86_400)
            let model = OverviewViewModel(understanding: OverviewPreviewUnderstanding(state),
                                          selectedDate: PreviewUnderstandingReader.sampleNow,
                                          calendar: PreviewUnderstandingReader.sampleCalendar,
                                          healthLoader: { nil }, now: { now })
            await model.reload()
            if let select, let block = model.blocks.first(where: { $0.id == select }) {
                model.select(block)
            }
            if showSearches, let fact = model.overview?.facts.first(where: { $0.kind == .searched }) {
                model.perform(fact)
            }
            let view = OverviewPlace(model: model, reader: brain, open: { _ in }, search: { _ in },
                                     hover: hover, noticedOpen: noticedOpen)
            let url = directory.appendingPathComponent("\(name).png")
            try await render(view, height: height, dark: dark, thumbnails: thumbnails, to: url)
            written.append(url)
        }

        func you(_ name: String, _ state: OverviewPreviewUnderstanding.State, height: CGFloat = 1_500,
                 dark: Bool = false, open: Bool = false, forget: Int64? = nil) async throws {
            let model = UserModelViewModel(understanding: OverviewPreviewUnderstanding(state), verdicts: verdicts,
                                           deletions: MemoryDeletionSignal(center: NotificationCenter()))
            await model.reload()
            if let forget, let item = model.page?.shared.first(where: { $0.id == forget }) {
                model.forget(item)
            }
            let view = YouPlace(model: model, open: { _ in }, keptBackOpen: open, notSeenOpen: open,
                                firstWhyOpen: !open)
            let url = directory.appendingPathComponent("\(name).png")
            try await render(view, height: height, dark: dark, thumbnails: thumbnails, to: url)
            written.append(url)
        }

        let competitorPricing: Int64 = 1_791_837_660_000_000
        let taxRounding: Int64 = 1_791_828_150_000_000
        try await overview("overview-today-first-screen", .today, height: firstScreen)
        try await overview("overview-today", .today)
        try await overview("overview-today-selected", .today, select: competitorPricing, noticedOpen: true)
        try await overview("overview-today-hover", .today, height: firstScreen, select: competitorPricing,
                           hover: .session(taxRounding))
        try await overview("overview-today-searches", .today, select: taxRounding, showSearches: true)
        try await overview("overview-today-empty", .todayEmpty, height: firstScreen)
        try await overview("overview-past-day", .pastDay, today: false)
        try await overview("overview-past-day-empty", .pastDayEmpty, height: firstScreen, today: false)
        try await overview("overview-model-off", .modelOff)
        try await overview("overview-no-ai-tool", .noAITool, height: firstScreen)
        try await overview("overview-unavailable", .unavailable, height: firstScreen)
        try await overview("overview-today-dark", .today, dark: true, select: competitorPricing, noticedOpen: true)

        try await you("you", .today)
        try await you("you-first-screen", .today, height: firstScreen)
        try await you("you-closed-sections-open", .today, height: 2_100, open: true)
        try await you("you-forgotten", .today, forget: 37)
        try await you("you-model-off", .modelOff)
        try await you("you-nothing-learned", .nothingLearned, height: firstScreen)
        try await you("you-nothing-learned-model-off", .nothingLearnedModelOff, height: firstScreen)
        try await you("you-unavailable", .unavailable, height: firstScreen)
        try await you("you-dark", .today, dark: true)
        return written
    }

    /// A verdict inbox in a new temporary folder: "Forget" writes there, never
    /// to the folder the agent reads.
    private static func temporaryVerdicts() throws -> VerdictInbox {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-preview-verdicts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return VerdictInbox(directory: folder, environment: [:])
    }

    private static func render<V: View>(
        _ view: V,
        height: CGFloat,
        dark: Bool,
        thumbnails: OverviewPreviewThumbnails,
        to url: URL
    ) async throws {
        let size = CGSize(width: width, height: height)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Drawn as the window shows them: a picture cannot be clicked, so
        // controls are drawn enabled and active, as in the app.
        let root = view
            .environment(\.isSyntheticPreview, false)
            .environment(\.controlActiveState, .key)
            .environment(\.overviewThumbnails, thumbnails)
            .environment(\.timeZone, PreviewUnderstandingReader.sampleTimeZone)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height)
            .background(MCI.Color.background)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = appearance
        // Hosted in a window so SwiftUI runs its tasks; the window is never
        // ordered on screen.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        defer { window.contentView = nil }

        // Ready when the screenshots have stopped arriving: a screenshot is
        // read in two steps (its moment, then its image), so allow both to
        // start before deciding nothing more is coming.
        let started = Date()
        var last = -1
        var stableSince = started
        let deadline = started.addingTimeInterval(8)
        while Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            let count = thumbnails.count
            if count != last {
                last = count
                stableSince = Date()
            } else if Date().timeIntervalSince(started) >= 1.5, Date().timeIntervalSince(stableSince) >= 0.5 {
                break
            }
        }
        hosting.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { throw CocoaError(.fileWriteUnknown) }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
#endif
