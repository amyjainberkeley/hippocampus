import CoreGraphics
import CoreVideo
import Foundation
import MCIKeyframeCodec
import XCTest
@testable import MCICaptureHelperKit

/// When a picture of a window beside the one in front is kept (SPEC 6.2),
/// and that one never is when its text is held back. Every frame, window
/// and setting here is made up; nothing reads the person's own settings.
final class SideWindowPicturePolicyTests: XCTestCase {
    private let minute: UInt64 = 60_000_000

    private func text(_ lines: [String]) -> SideWindowText { SideWindowText(lines: lines) }

    private let tenLines = (1...10).map { "Line \($0) of the channel" }

    // MARK: Rule 5 — calls and video

    func testCallsAndVideoAreNeverPictured() {
        for app in ["us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime", "com.cisco.webexmeetingsapp",
                    "com.apple.TV", "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina"] {
            XCTAssertTrue(SideWindowPicturePolicy.isCallOrVideo(bundleId: app, title: "Anything"), app)
        }
        for title in ["Meet - abc-defg-hij", "Meet \u{2013} Team sync", "Rounding explained - YouTube",
                      "Netflix", "Weekly stream - Twitch", "Launch film on Vimeo", "Huddle in #launch",
                      "Daily standup | Microsoft Teams", "Zoom Meeting"] {
            XCTAssertTrue(SideWindowPicturePolicy.isCallOrVideo(bundleId: "com.google.Chrome", title: title), title)
        }
        for (app, title) in [("com.tinyspeck.slackmacgap", "launch (Channel) - Northwind Studio - Slack"),
                             ("com.google.Chrome", "Meeting notes - Google Docs"),
                             ("com.apple.Notes", "Launch checklist"), ("com.apple.mail", nil)] {
            XCTAssertFalse(SideWindowPicturePolicy.isCallOrVideo(bundleId: app, title: title), title ?? app)
        }
    }

    // MARK: Rules 2 and 6 — the ledger

    func testTheFirstPictureOfAWindowIsKept() {
        let ledger = SidePictureLedger()
        XCTAssertNil(ledger.admits(windowId: 1, titleKey: 1, text: text(tenLines), nowUs: 10 * minute))
        XCTAssertNil(ledger.admitsPicture(windowId: 1, dhash: DHash(bits: 0), nowUs: 10 * minute))
    }

    func testUnchangedTextKeepsNoNewPicture() {
        var ledger = SidePictureLedger()
        ledger.record(windowId: 1, titleKey: 1, text: text(tenLines), dhash: DHash(bits: 0), nowUs: 0)
        XCTAssertEqual(ledger.admits(windowId: 1, titleKey: 1, text: text(tenLines), nowUs: 10 * minute),
                       .textUnchanged)
        // Two of ten similar lines changed: neither three lines nor 15%.
        var two = tenLines
        two[0] = "Line 1 changed"
        two[1] = "Line 2 changed"
        XCTAssertEqual(ledger.admits(windowId: 1, titleKey: 1, text: text(two), nowUs: 10 * minute), .textUnchanged)
    }

    func testThreeChangedLinesOrFifteenPercentOrANewTitleIsMeaningful() {
        var ledger = SidePictureLedger()
        ledger.record(windowId: 1, titleKey: 1, text: text(tenLines), dhash: DHash(bits: 0), nowUs: 0)
        let three = tenLines + ["New one", "New two", "New three"]
        XCTAssertNil(ledger.admits(windowId: 1, titleKey: 1, text: text(three), nowUs: 10 * minute))
        // One long new line is more than 15% of the text.
        let long = tenLines + [String(repeating: "A long new paragraph. ", count: 4)]
        XCTAssertNil(ledger.admits(windowId: 1, titleKey: 1, text: text(long), nowUs: 10 * minute))
        // A new title, with the same text.
        XCTAssertNil(ledger.admits(windowId: 1, titleKey: 2, text: text(tenLines), nowUs: 10 * minute))
    }

    func testOnePictureAWindowEveryTwoMinutesSoonerOnlyForANewTitle() {
        var ledger = SidePictureLedger()
        ledger.record(windowId: 1, titleKey: 1, text: text(tenLines), dhash: DHash(bits: 0), nowUs: 0)
        let changed = tenLines + ["New one", "New two", "New three"]
        XCTAssertEqual(ledger.admits(windowId: 1, titleKey: 1, text: text(changed), nowUs: 2 * minute - 1), .tooSoon)
        XCTAssertNil(ledger.admits(windowId: 1, titleKey: 1, text: text(changed), nowUs: 2 * minute))
        XCTAssertNil(ledger.admits(windowId: 1, titleKey: 9, text: text(changed), nowUs: minute))
        // Another window is not held back by this one.
        XCTAssertNil(ledger.admits(windowId: 2, titleKey: 1, text: text(changed), nowUs: minute))
    }

    func testAtMostThirtyAnHourAndThreeHundredADay() {
        var ledger = SidePictureLedger()
        for n in 0..<30 {
            ledger.record(windowId: CGWindowID(n), titleKey: 0, text: text(["x"]), dhash: DHash(bits: 0),
                          nowUs: UInt64(n) * minute)
        }
        XCTAssertEqual(ledger.admits(windowId: 99, titleKey: 0, text: text(["x"]), nowUs: 59 * minute), .hourlyLimit)
        XCTAssertNil(ledger.admits(windowId: 99, titleKey: 0, text: text(["x"]), nowUs: 61 * minute))

        var day = SidePictureLedger()
        for n in 0..<300 {
            day.record(windowId: CGWindowID(n), titleKey: 0, text: text(["x"]), dhash: DHash(bits: 0),
                       nowUs: UInt64(n) * 4 * minute)
        }
        let afterLast = UInt64(299) * 4 * minute + 2 * 60 * minute
        XCTAssertEqual(day.admits(windowId: 999, titleKey: 0, text: text(["x"]), nowUs: afterLast), .dailyLimit)
    }

    func testAPictureMustChangeVisiblyUnlessTheLastOneIsHalfAnHourOld() {
        var ledger = SidePictureLedger()
        ledger.record(windowId: 1, titleKey: 1, text: text(tenLines), dhash: DHash(bits: 0), nowUs: 0)
        XCTAssertEqual(ledger.admitsPicture(windowId: 1, dhash: DHash(bits: 0b111_111_111_11), nowUs: 5 * minute),
                       .pictureUnchanged)
        XCTAssertNil(ledger.admitsPicture(windowId: 1, dhash: DHash(bits: 0b1111_1111_1111), nowUs: 5 * minute))
        XCTAssertNil(ledger.admitsPicture(windowId: 1, dhash: DHash(bits: 0), nowUs: 30 * minute))
    }

    // MARK: Rules 7 and 8 — settings, room and power

    func testSettingsReadAsOffUnlessTheFileSaysYes() {
        XCTAssertFalse(SidePictureSettings.parse("").enabled)
        XCTAssertFalse(SidePictureSettings.parse("side_window_pictures = false").enabled)
        XCTAssertTrue(SidePictureSettings.parse("capture_enabled = true\nside_window_pictures = true\n").enabled)
        XCTAssertTrue(SidePictureSettings.parse("side_window_pictures = true # on").enabled)
        for damaged in ["side_window_pictures = \"true\"", "side_window_pictures = 1",
                        "side_window_pictures = true\nside_window_pictures = true",
                        "this is not toml\nside_window_pictures = true",
                        "[table]\nside_window_pictures = true"] {
            XCTAssertFalse(SidePictureSettings.parse(damaged).enabled, damaged)
        }
    }

    func testTheBudgetIsTheChoiceOrTwoGigabytesOrTwoPercentOfTheDisk() {
        XCTAssertEqual(SidePictureSettings.parse("side_pictures_budget_mb = 1000").budgetBytes(diskTotalBytes: nil),
                       1_000_000_000)
        XCTAssertEqual(SidePictureSettings.parse("side_pictures_budget_mb = 5000").budgetBytes(
            diskTotalBytes: 50_000_000_000), 5_000_000_000)
        XCTAssertNil(SidePictureSettings.parse("side_pictures_budget_mb = 3000").budgetMB)
        XCTAssertEqual(SidePictureSettings().budgetBytes(diskTotalBytes: 1_000_000_000_000), 2_000_000_000)
        XCTAssertEqual(SidePictureSettings().budgetBytes(diskTotalBytes: 50_000_000_000), 1_000_000_000)
        XCTAssertEqual(SidePictureSettings().budgetBytes(diskTotalBytes: nil), 2_000_000_000)
    }

    func testTheDiskFloorPausesBelowTenGigabytesAndResumesAboveTwelve() {
        var floor = SidePictureDiskFloor()
        XCTAssertFalse(floor.update(availableBytes: 11_000_000_000))
        XCTAssertTrue(floor.update(availableBytes: 9_999_999_999))
        XCTAssertTrue(floor.update(availableBytes: 11_500_000_000))
        XCTAssertTrue(floor.update(availableBytes: nil))
        XCTAssertFalse(floor.update(availableBytes: 12_000_000_001))
    }

    func testLowPowerModeAndLowBatteryKeepNoSidePictures() {
        XCTAssertFalse(CapturePower.allowsSidePictures(mode: .lowPower, batteryPercent: 100))
        XCTAssertFalse(CapturePower.allowsSidePictures(mode: .battery, batteryPercent: 19))
        XCTAssertTrue(CapturePower.allowsSidePictures(mode: .battery, batteryPercent: 20))
        XCTAssertTrue(CapturePower.allowsSidePictures(mode: .pluggedIn, batteryPercent: 5))
        XCTAssertTrue(CapturePower.allowsSidePictures(mode: .battery, batteryPercent: nil))
    }

    // MARK: The retainer

    private final class FakeEnvironment: SidePictureEnvironment, @unchecked Sendable {
        var settingsValue = SidePictureSettings(enabled: true)
        var powerValue: (mode: CapturePowerMode, batteryPercent: Int?) = (.pluggedIn, nil)
        var diskValue: (availableBytes: Int64?, totalBytes: Int64?) = (500_000_000_000, 1_000_000_000_000)
        var recorded: (bytes: Int64, measuredAt: Date)?
        func settings() -> SidePictureSettings { settingsValue }
        func power() -> (mode: CapturePowerMode, batteryPercent: Int?) { powerValue }
        func disk() -> (availableBytes: Int64?, totalBytes: Int64?) { diskValue }
        func recordedSideBytes() -> (bytes: Int64, measuredAt: Date)? { recorded }
    }

    private let key = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 600)

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("side-pictures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A 2000x1200 frame: a page shading from dark to light across, with
    /// darker text stripes, so the picture is not one colour. `reversed`
    /// shades the other way, a visibly different picture.
    private func frame(reversed: Bool = false) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 2000, 1200, kCVPixelFormatType_32BGRA, nil, &buffer)
                     == kCVReturnSuccess)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<1200 {
            for x in 0..<2000 {
                let p = base + y * bytesPerRow + x * 4
                let across = reversed ? 1999 - x : x
                var value = 40 + across * 200 / 2000
                if (y / 20) % 3 == 0, (x / 8) % 5 != 0 { value -= 30 }
                p[0] = UInt8(value); p[1] = UInt8(value); p[2] = UInt8(value); p[3] = 255
            }
        }
        return pixels
    }

    private func candidate(window: CGWindowID = 3, title: String = "launch", lines: [String]? = nil,
                           tsUs: UInt64 = 1_000 * 60_000_000) throws -> SidePictureCandidate {
        let side = VisibleWindow(windowId: window, bundleId: "com.tinyspeck.slackmacgap", title: title,
                                 bounds: CGRect(x: 100, y: 100, width: 600, height: 400), layer: 0)
        let plan = try XCTUnwrap(WindowPictureCrop.plan(for: side, displayBounds: display,
                                                        pixelSize: CGSize(width: 2000, height: 1200),
                                                        windows: [side], excludedBundleIds: []))
        return SidePictureCandidate(windowId: window, title: title, text: text(lines ?? tenLines), plan: plan,
                                    tsUs: tsUs)
    }

    private func retainer(_ environment: FakeEnvironment, folder: URL) -> SidePictureRetainer {
        SidePictureRetainer(keyMaterial: key, store: AtomicKeyframeBlobStore(blobDirectory: folder),
                            environment: environment, policy: .default, now: Date.init)
    }

    private func blobs(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "bin" }
    }

    func testAKeptPictureIsSealedWithTheBrainsKeyAndOpensAsAMetadataFreeJPEG() async throws {
        let folder = try temporaryDirectory()
        let environment = FakeEnvironment()
        let sides = retainer(environment, folder: folder)
        let retention = try await sides.retain(frame: KeyframePixelInput(pixelBuffer: frame()), candidate: candidate())
        let kept = try XCTUnwrap(retention)
        await sides.confirm(kept)
        let files = blobs(in: folder)
        XCTAssertEqual(files.map(\.lastPathComponent), ["\(kept.lowercaseHexDigest).bin"])
        let sealed = try Data(contentsOf: files[0])
        let jpeg = try KeyframeBlobCodec.open(blob: sealed, keyMaterial: key)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil)), 0, nil))
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 800)
    }

    func testNothingIsKeptWhenOffOnLowPowerLowBatteryLowDiskOrAFullBudget() async throws {
        let cases: [(String, (FakeEnvironment) -> Void, SidePictureSkip)] = [
            ("off", { $0.settingsValue = SidePictureSettings(enabled: false) }, .off),
            ("low power", { $0.powerValue = (.lowPower, 80) }, .lowPower),
            ("low battery", { $0.powerValue = (.battery, 19) }, .lowBattery),
            ("low disk", { $0.diskValue = (9_000_000_000, 500_000_000_000) }, .lowDisk),
            ("budget full", { $0.recorded = (2_000_000_000, Date()) }, .budgetFull),
        ]
        for (name, setUp, reason) in cases {
            let folder = try temporaryDirectory()
            let environment = FakeEnvironment()
            setUp(environment)
            let sides = retainer(environment, folder: folder)
            let retention = try await sides.retain(frame: KeyframePixelInput(pixelBuffer: frame()),
                                                   candidate: candidate())
            XCTAssertNil(retention, name)
            let skip = await sides.lastSkip
            XCTAssertEqual(skip, reason, name)
            XCTAssertTrue(blobs(in: folder).isEmpty, name)
        }
    }

    func testPicturesKeptSinceTheAgentsLastMeasureCountTowardTheBudget() async throws {
        let folder = try temporaryDirectory()
        let environment = FakeEnvironment()
        let measured = Date().addingTimeInterval(-60)
        let first = try candidate(window: 1)
        // Just under a 1 GB budget at the agent's last measure.
        environment.settingsValue = SidePictureSettings(enabled: true, budgetMB: 1_000)
        environment.recorded = (999_999_000, measured)
        let sides = retainer(environment, folder: folder)
        let kept = try await sides.retain(frame: KeyframePixelInput(pixelBuffer: frame()), candidate: first)
        await sides.confirm(try XCTUnwrap(kept))
        // That picture filled it: the next window waits for thinning.
        let next = try await sides.retain(frame: KeyframePixelInput(pixelBuffer: frame()),
                                          candidate: candidate(window: 2))
        XCTAssertNil(next)
        let skip = await sides.lastSkip
        XCTAssertEqual(skip, .budgetFull)
        // A newer measure from the agent replaces the running count.
        environment.recorded = (100, Date().addingTimeInterval(1))
        let after = try await sides.retain(frame: KeyframePixelInput(pixelBuffer: frame()),
                                           candidate: candidate(window: 2))
        XCTAssertNotNil(after)
    }

    func testTheSameWindowIsNotPicturedAgainTooSoonAndAnUnchangedPictureIsNotKept() async throws {
        let folder = try temporaryDirectory()
        let sides = retainer(FakeEnvironment(), folder: folder)
        let start: UInt64 = 1_000 * 60_000_000
        let first = try await sides.retain(frame: KeyframePixelInput(pixelBuffer: frame()),
                                           candidate: candidate(tsUs: start))
        await sides.confirm(try XCTUnwrap(first))
        let changed = tenLines + ["A", "B", "C"]
        let soon = try await sides.retain(frame: KeyframePixelInput(pixelBuffer: frame()),
                                          candidate: candidate(lines: changed, tsUs: start + 60_000_000))
        XCTAssertNil(soon)
        var skip = await sides.lastSkip
        XCTAssertEqual(skip, .tooSoon)
        // Three minutes on, the text changed but the picture did not.
        let same = try await sides.retain(frame: KeyframePixelInput(pixelBuffer: frame()),
                                          candidate: candidate(lines: changed, tsUs: start + 3 * 60_000_000))
        XCTAssertNil(same)
        skip = await sides.lastSkip
        XCTAssertEqual(skip, .pictureUnchanged)
        // A visibly different picture is kept.
        let moved = try await sides.retain(frame: KeyframePixelInput(pixelBuffer: frame(reversed: true)),
                                           candidate: candidate(lines: changed, tsUs: start + 3 * 60_000_000))
        XCTAssertNotNil(moved)
        XCTAssertEqual(blobs(in: folder).count, 2)
    }

    func testADiscardedPictureLeavesNothingOnDisk() async throws {
        let folder = try temporaryDirectory()
        let sides = retainer(FakeEnvironment(), folder: folder)
        let kept = try await sides.retain(frame: KeyframePixelInput(pixelBuffer: frame()), candidate: candidate())
        try await sides.discard(try XCTUnwrap(kept))
        XCTAssertTrue(blobs(in: folder).isEmpty)
        // A discarded picture never counts: the window may be pictured now.
        let again = try await sides.retain(frame: KeyframePixelInput(pixelBuffer: frame()), candidate: candidate())
        XCTAssertNotNil(again)
    }

    // MARK: The privacy path

    /// A side window's text with a secret in it: a tombstone, and no
    /// picture is made or kept. With clean text, its moment carries the
    /// picture's digest as a context event.
    func testAHeldBackWindowNeverGetsAPictureAndACleanOneCarriesItsDigest() async throws {
        let folder = try temporaryDirectory()
        let sides = retainer(FakeEnvironment(), folder: folder)
        let side = try candidate()
        let sink = SideRecordingSink()
        await CascadeTwiceOCREmitter.handleOCRResult(
            tsUs: 1, context: WorkflowContext(appBundleId: "com.example.app", windowTitle: "launch"),
            result: OCRResult(recognizedLines: [OCRLine(text: "password: synthetic-example", boundingBox: .zero,
                                                        confidence: 1)], durationMs: 1, timedOut: false),
            cascade: Self.allowCascade(), sink: sink, sequence: FrameSequence(), counters: HelperHealthCounters(),
            pixelBuffer: frame(), keyframeRetainer: SidePictureRetention(retainer: sides, candidate: side),
            evidenceCandidate: SidePictureRetention(retainer: sides, candidate: side).evidence, background: true)
        var frames = await sink.frames()
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames[0][2] == 0x11 && frames[0][3] == 0, "a tombstone")
        XCTAssertTrue(blobs(in: folder).isEmpty)

        await CascadeTwiceOCREmitter.handleOCRResult(
            tsUs: 2, context: WorkflowContext(appBundleId: "com.example.app", windowTitle: "launch"),
            result: OCRResult(recognizedLines: tenLines.map { OCRLine(text: $0, boundingBox: .zero, confidence: 1) },
                              durationMs: 1, timedOut: false),
            cascade: Self.allowCascade(), sink: sink, sequence: FrameSequence(), counters: HelperHealthCounters(),
            pixelBuffer: frame(), keyframeRetainer: SidePictureRetention(retainer: sides, candidate: side),
            evidenceCandidate: SidePictureRetention(retainer: sides, candidate: side).evidence, background: true)
        frames = await sink.frames()
        XCTAssertEqual(frames.count, 2)
        let event = frames[1]
        // A context event (0x0041), carrying the kept picture's digest.
        XCTAssertEqual(Array(event[2...3]), [0x41, 0x00])
        let offset = minFrameHeaderBytes + 8 + 8 + ocrEventAppBundleIdLen + 2 + 2 + 4
        let digest = Array(event[offset..<(offset + ocrEventKeyframeHashLen)])
        XCTAssertFalse(digest.allSatisfy { $0 == 0 })
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(blobs(in: folder).map(\.lastPathComponent), ["\(hex).bin"])
    }

    func testOnlyWindowsWorthAPictureBecomeCandidates() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let size = CGSize(width: 2000, height: 1200)
        func candidate(_ window: VisibleWindow, _ windows: [VisibleWindow]? = nil) -> SidePictureCandidate? {
            BackgroundCapturePolicy.sidePictureCandidate(
                for: window, lines: [OCRLine(text: "hello", boundingBox: .zero, confidence: 1)],
                displayBounds: display, pixelSize: size, windows: windows ?? [window],
                excludedBundleIds: [], tsUs: 1)
        }
        let notes = VisibleWindow(windowId: 1, bundleId: "com.apple.Notes", title: "Launch checklist",
                                  bounds: CGRect(x: 100, y: 100, width: 600, height: 400), layer: 0)
        XCTAssertNotNil(candidate(notes))
        let call = VisibleWindow(windowId: 2, bundleId: "us.zoom.xos", title: "Zoom Meeting",
                                 bounds: CGRect(x: 100, y: 100, width: 600, height: 400), layer: 0)
        XCTAssertNil(candidate(call))
        let video = VisibleWindow(windowId: 3, bundleId: "com.google.Chrome", title: "Launch film - YouTube",
                                  bounds: CGRect(x: 100, y: 100, width: 600, height: 400), layer: 0)
        XCTAssertNil(candidate(video))
        let covered = VisibleWindow(windowId: 4, bundleId: "com.microsoft.VSCode", title: "tax.rs",
                                    bounds: CGRect(x: 0, y: 0, width: 1000, height: 600), layer: 0)
        XCTAssertNil(candidate(notes, [covered, notes]))
        let panel = VisibleWindow(windowId: 5, bundleId: "com.apple.Notes", title: "Inspector",
                                  bounds: CGRect(x: 100, y: 100, width: 600, height: 400), layer: 3)
        XCTAssertNil(candidate(panel))
    }

    /// A whole-screen read stores each side window as its own moment; a
    /// private browser window is dropped and never pictured, a call keeps its
    /// text and gets no picture, an ordinary window may get one.
    func testAPrivateBrowserWindowBesideIsDroppedAndACallKeepsOnlyItsText() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let lines = [OCRLine(text: "hello", boundingBox: CGRect(x: 0.3, y: 0.5, width: 0.1, height: 0.02),
                             confidence: 1)]
        func read(_ window: VisibleWindow) -> CascadeTwiceOCREmitter.BackgroundWindow? {
            BackgroundCapturePolicy.backgroundWindow(
                window, lines: lines, displayBounds: display, pixelSize: CGSize(width: 2000, height: 1200),
                pixelsPerPoint: 2, windows: [window], excludedBundleIds: [],
                denylist: SensitiveCaptureDenylist(entries: []), tsUs: 1, privateWindows: PrivateBrowserWindows())
        }
        let bounds = CGRect(x: 100, y: 100, width: 600, height: 400)
        XCTAssertNil(read(VisibleWindow(windowId: 1, bundleId: "com.google.Chrome", title: "New Incognito Tab",
                                        bounds: bounds, layer: 0)))
        let call = read(VisibleWindow(windowId: 2, bundleId: "us.zoom.xos", title: "Zoom Meeting", bounds: bounds,
                                      layer: 0))
        XCTAssertNotNil(call)
        XCTAssertNil(call?.sidePicture)
        let notes = read(VisibleWindow(windowId: 3, bundleId: "com.apple.Notes", title: "Launch checklist",
                                       bounds: bounds, layer: 0))
        XCTAssertEqual(notes?.context.appBundleId, "com.apple.Notes")
        XCTAssertEqual(notes?.sidePicture?.windowId, 3)
        XCTAssertEqual(notes?.sidePicture?.plan.crop, CGRect(x: 200, y: 200, width: 1200, height: 800))
    }

    // MARK: The live environment's files

    func testOnlyAPrivateSettingsFileOwnedByThisUserTurnsThemOn() throws {
        let folder = try temporaryDirectory()
        let settings = folder.appendingPathComponent("runtime.toml")
        try "side_window_pictures = true\nside_pictures_budget_mb = 5000\n".write(to: settings, atomically: true,
                                                                                     encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path)
        let environment = LiveSidePictureEnvironment(settingsURL: settings,
                                                     usageURL: folder.appendingPathComponent("pictures-usage.json"),
                                                     blobDirectory: folder)
        XCTAssertEqual(environment.settings(), SidePictureSettings(enabled: true, budgetMB: 5_000))
        // Anyone may change it: off.
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: settings.path)
        XCTAssertFalse(environment.settings().enabled)
        // A link to it: off.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path)
        let link = folder.appendingPathComponent("link.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: settings)
        XCTAssertFalse(LiveSidePictureEnvironment(settingsURL: link, usageURL: link, blobDirectory: folder)
            .settings().enabled)
        // Missing: off.
        XCTAssertFalse(LiveSidePictureEnvironment(settingsURL: folder.appendingPathComponent("none.toml"),
                                                  usageURL: link, blobDirectory: folder).settings().enabled)
    }

    func testTheAgentsUsageRecordIsRead() throws {
        let folder = try temporaryDirectory()
        let usage = folder.appendingPathComponent("pictures-usage.json")
        try Data("""
            {"schema_version":1,"updated_at":"2026-10-12T21:00:00.000Z","front_bytes":5,"side_bytes":640000000,
             "side_count":3,"side_budget_bytes":2000000000,"side_pictures_on":true}
            """.utf8).write(to: usage)
        let environment = LiveSidePictureEnvironment(settingsURL: folder.appendingPathComponent("none.toml"),
                                                     usageURL: usage, blobDirectory: folder)
        XCTAssertEqual(environment.recordedSideBytes()?.bytes, 640_000_000)
        XCTAssertNotNil(environment.disk().totalBytes)
    }

    // MARK: Fixtures

    private static func allowCascade() -> SuppressionCascade {
        SuppressionCascade(
            secureEventInput: NoSecureInput(), axSecureSubrole: NonSecureAX(), denylist: NoDenylist(),
            blackedRegion: NoBlackRegion(), knownSafeAppBundles: ["com.example.app"])
    }
}

private actor SideRecordingSink: FrameSink {
    private var recorded: [Data] = []
    func write(_ bytes: Data) throws { recorded.append(bytes) }
    func frames() -> [Data] { recorded }
}

private struct NoSecureInput: SecureEventInputProbe {
    func isSecureEventInputEnabled() -> Bool { false }
}

private struct NonSecureAX: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { false }
}

private struct NoDenylist: DenylistProbe {
    func appIsDenied(bundleId _: String) -> Bool { false }
    func urlIsDenied(_: String) -> Bool { false }
    func windowTitleIsDenied(_: String) -> Bool { false }
}

private struct NoBlackRegion: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}
