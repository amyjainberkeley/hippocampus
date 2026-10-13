import CoreVideo
import Foundation
import XCTest

@testable import MCICaptureHelperKit

/// RULINGS G8: browsers are read like every other window, on the focused path
/// and on the whole screen, and a window that shows it is private is skipped
/// before anything is stored. All titles, addresses and text are made up.
final class BrowserPrivateWindowTests: XCTestCase {
    // A 1200 × 800 pt window read at 2 px per point: its top bar is the top
    // 120 pt, the top 0.15 of the frame.
    static let pixelSize = CGSize(width: 2400, height: 1600)
    static let focusedWindow = OCRWindowGeometry(rect: CGRect(x: 0, y: 0, width: 1, height: 1), pixelsPerPoint: 2,
                                                 title: "Example", bundleId: "com.google.Chrome")

    static func line(_ text: String, x: CGFloat = 0.30, y: CGFloat, width: CGFloat = 0.40) -> OCRLine {
        OCRLine(text: text, boundingBox: CGRect(x: x, y: y, width: width, height: 0.015), confidence: 1)
    }

    /// Tabs and the address bar in the top bar, then a page.
    static func page(topBar: [OCRLine] = [], body: [String] = ["The release notes cover the new reading order.",
                                                               "Each window keeps its content before its chrome."]) -> [OCRLine] {
        [line("Release notes", x: 0.08, y: 0.965, width: 0.10),
         line("example.org/notes", x: 0.30, y: 0.925, width: 0.20)]
            + topBar
            + body.enumerated().map { line($0.element, x: 0.10, y: 0.70 - 0.03 * CGFloat($0.offset), width: 0.60) }
    }

    static func cascade(
        privateWindows: PrivateBrowserWindows = PrivateBrowserWindows(),
        probe: (any BrowserWindowPrivacyChecking)? = nil,
        denylist: SensitiveCaptureDenylist = SensitiveCaptureDenylist(entries: [])
    ) -> SuppressionCascade {
        SuppressionCascade(
            secureEventInput: NoSecureInput(), axSecureSubrole: NonSecureAX(),
            denylist: denylist, blackedRegion: NoBlackedRegion(),
            browserAppBundles: BrowserPixelCapturePolicy.browserBundleIds,
            admissionPolicy: .ordinaryApplications,
            browserWindowPrivacy: probe,
            privateWindows: privateWindows
        )
    }

    // MARK: - Normal browser windows are read on both paths

    func testANormalBrowserWindowIsReadOnTheFocusedPath() {
        let cascade = Self.cascade(probe: AnswersPrivate(answer: false))
        for bundle in ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser",
                       "com.brave.Browser", "com.microsoft.edgemac"] {
            let window = FocusedWindow(bundleId: bundle, windowId: 10, axRect: CGRect(x: 0, y: 25, width: 1200, height: 800))
            let context = WorkflowContext(appBundleId: bundle, windowTitle: "Release notes")
            XCTAssertEqual(cascade.snapshotPixelPrivacy(context: context, capturedWindow: window).decision, .allow, bundle)
        }
    }

    func testANormalBrowserWindowIsReadOnTheWholeScreen() {
        let excluded = BackgroundCapturePolicy.excludedBundleIds(userEntries: [])
        for bundle in BrowserPixelCapturePolicy.browserBundleIds {
            XCTAssertFalse(BackgroundCapturePolicy.isExcluded(bundle, from: excluded), bundle)
        }
        let display = CGRect(x: 0, y: 0, width: 1200, height: 825)
        let chrome = VisibleWindow(windowId: 7, bundleId: "com.google.Chrome", title: "Release notes",
                                   bounds: CGRect(x: 0, y: 25, width: 1200, height: 800), layer: 0)
        let lines = [Self.line("The release notes cover the new reading order.", y: 0.5)]
        let groups = BackgroundCapturePolicy.attribute(
            lines: lines, displayBounds: display, windows: [chrome], excludedBundleIds: excluded,
            focusedWindowId: nil, denylist: SensitiveCaptureDenylist(entries: []))
        XCTAssertEqual(groups.map(\.window.windowId), [7])
        let placed = BackgroundCapturePolicy.geometry(of: chrome, displayBounds: display, pixelsPerPoint: 2,
                                                      windows: [chrome], excludedBundleIds: excluded)
        XCTAssertFalse(BackgroundCapturePolicy.skipsBrowserWindow(
            chrome, lines: Self.page(), geometry: placed.geometry, pixelSize: CGSize(width: 2400, height: 1650),
            denylist: SensitiveCaptureDenylist(entries: []), privateWindows: PrivateBrowserWindows()))
    }

    func testANormalBrowserPageIsStored() async {
        let frames = await Self.drive(Self.page())
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first.map(Self.isTombstone), false)
    }

    // MARK: - Title markers

    func testEachPrivateTitleMarkerSkipsTheWindow() {
        let titles = ["Release notes — Private Browsing", "New Incognito Tab", "New InPrivate tab",
                      "Mozilla Firefox — Private Browsing"]
        for title in titles {
            let window = FocusedWindow(bundleId: "com.google.Chrome", windowId: 11)
            let decision = Self.cascade().snapshotPixelPrivacy(
                context: WorkflowContext(appBundleId: "com.google.Chrome", windowTitle: title), capturedWindow: window
            ).decision
            XCTAssertEqual(decision, .suppress(reason: .denylistSource), title)

            let visible = VisibleWindow(windowId: 12, bundleId: "org.mozilla.firefox", title: title,
                                        bounds: CGRect(x: 0, y: 25, width: 1200, height: 800), layer: 0)
            XCTAssertFalse(BackgroundCapturePolicy.isEligible(
                visible, focusedWindowId: nil, excludedBundleIds: [], denylist: SensitiveCaptureDenylist(entries: [])), title)
            XCTAssertTrue(BackgroundCapturePolicy.skipsBrowserWindow(
                visible, lines: Self.page(), geometry: nil, pixelSize: Self.pixelSize,
                denylist: SensitiveCaptureDenylist(entries: []), privateWindows: PrivateBrowserWindows()), title)
        }
    }

    func testAWindowTitledAsANewPrivateTabStaysSkippedAfterItNavigates() {
        let memory = PrivateBrowserWindows()
        let cascade = Self.cascade(privateWindows: memory)
        let window = FocusedWindow(bundleId: "com.google.Chrome", windowId: 21)
        XCTAssertEqual(cascade.decide(context: WorkflowContext(appBundleId: "com.google.Chrome", windowTitle: "New Incognito Tab")),
                       .suppress(reason: .denylistSource))
        XCTAssertEqual(cascade.snapshotPixelPrivacy(
            context: WorkflowContext(appBundleId: "com.google.Chrome", windowTitle: "New Incognito Tab"),
            capturedWindow: window).decision, .suppress(reason: .denylistSource))
        // Chrome titles a window with its page alone once it navigates.
        XCTAssertEqual(cascade.snapshotPixelPrivacy(
            context: WorkflowContext(appBundleId: "com.google.Chrome", windowTitle: "Release notes"),
            capturedWindow: window).decision, .suppress(reason: .denylistSource))
        let other = FocusedWindow(bundleId: "com.google.Chrome", windowId: 22)
        XCTAssertEqual(cascade.snapshotPixelPrivacy(
            context: WorkflowContext(appBundleId: "com.google.Chrome", windowTitle: "Release notes"),
            capturedWindow: other).decision, .allow)
    }

    // MARK: - The top bar

    func testIncognitoInTheTopBarSkipsTheFrameButIncognitoOnThePageDoesNot() async {
        let chip = Self.line("Incognito", x: 0.86, y: 0.925, width: 0.06)
        let privateFrame = Self.page(topBar: [chip])
        XCTAssertEqual(BrowserPixelCapturePolicy.topBarFinding(
            privateFrame, window: Self.focusedWindow.rect, pixelSize: Self.pixelSize, pixelsPerPoint: 2,
            denylist: SensitiveCaptureDenylist(entries: [])), .privateWindow)
        let frames = await Self.drive(privateFrame)
        XCTAssertEqual(frames.map(Self.isTombstone), [true])
        XCTAssertEqual(frames.first?.last, RedactionReason.denylistSource.rawValue)

        let article = Self.page(body: ["Incognito mode keeps no history on this Mac.",
                                       "Open an incognito window from the File menu."])
        XCTAssertNil(BrowserPixelCapturePolicy.topBarFinding(
            article, window: Self.focusedWindow.rect, pixelSize: Self.pixelSize, pixelsPerPoint: 2,
            denylist: SensitiveCaptureDenylist(entries: [])))
        let stored = await Self.drive(article)
        XCTAssertEqual(stored.map(Self.isTombstone), [false])
    }

    func testEachTopBarMarkerIsAWholeWord() {
        let markers = ["Incognito", "Incognito (2)", "InPrivate", "Private Browsing", "Private", "PRIVATE",
                       "Private window"]
        for marker in markers {
            XCTAssertTrue(BrowserPixelCapturePolicy.isPrivateMarker(marker), marker)
        }
        let ordinary = ["Private equity explained", "Incognitos", "privately", "Privacy settings",
                        "github.com/example/private-notes", "Release notes"]
        for text in ordinary {
            XCTAssertFalse(BrowserPixelCapturePolicy.isPrivateMarker(text), text)
        }
    }

    func testPrivateWordsInATabTitleSkipTheReadButAreNotRemembered() async {
        let tab = Self.line("Incognito (film) - Wikipedia", x: 0.08, y: 0.965, width: 0.2)
        XCTAssertEqual(BrowserPixelCapturePolicy.topBarFinding(
            [tab], window: Self.focusedWindow.rect, pixelSize: Self.pixelSize, pixelsPerPoint: 2,
            denylist: SensitiveCaptureDenylist(entries: [])), .privateWords)
        let memory = PrivateBrowserWindows()
        let frames = await Self.drive([tab] + Array(Self.page().dropFirst(2)), windowId: 81, memory: memory)
        XCTAssertEqual(frames.map(Self.isTombstone), [true])
        XCTAssertFalse(memory.contains(81), "a tab's title is not a badge")
        let next = await Self.drive(Self.page(), windowId: 81, memory: memory)
        XCTAssertEqual(next.map(Self.isTombstone), [false], "the next page in that window is read")
    }

    func testOnlyATitleNoNormalWindowHasIsRemembered() {
        let memory = PrivateBrowserWindows()
        let frame = CGRect(x: 0, y: 25, width: 1200, height: 800)
        BackgroundCapturePolicy.rememberPrivateBrowserWindows([
            VisibleWindow(windowId: 91, bundleId: "com.google.Chrome", title: "New Incognito Tab", bounds: frame, layer: 0),
            VisibleWindow(windowId: 92, bundleId: "com.google.Chrome", title: "Incognito (film) - Wikipedia", bounds: frame, layer: 0),
            VisibleWindow(windowId: 93, bundleId: "org.mozilla.firefox", title: "Release notes — Private Browsing", bounds: frame, layer: 0),
            VisibleWindow(windowId: 94, bundleId: "com.apple.TextEdit", title: "New Incognito Tab", bounds: frame, layer: 0),
        ], privateWindows: memory)
        XCTAssertTrue(memory.contains(91))
        XCTAssertFalse(memory.contains(92), "a page about the word is skipped while it shows, not remembered")
        XCTAssertTrue(memory.contains(93))
        XCTAssertFalse(memory.contains(94), "only browsers")
    }

    func testTheTopBarIsTheTop120PointsOfTheWindowOnly() {
        // 100 pt from the top is inside the bar; 140 pt is page.
        let inBar = Self.line("InPrivate", x: 0.05, y: 1 - 100.0 / 800, width: 0.06)
        let onPage = Self.line("InPrivate", x: 0.05, y: 1 - 140.0 / 800, width: 0.06)
        let window = Self.focusedWindow.rect
        XCTAssertEqual(BrowserPixelCapturePolicy.topBarFinding(
            [inBar], window: window, pixelSize: Self.pixelSize, pixelsPerPoint: 2,
            denylist: SensitiveCaptureDenylist(entries: [])), .privateWindow)
        XCTAssertNil(BrowserPixelCapturePolicy.topBarFinding(
            [onPage], window: window, pixelSize: Self.pixelSize, pixelsPerPoint: 2,
            denylist: SensitiveCaptureDenylist(entries: [])))
    }

    func testAnotherWindowsTopBarOnTheScreenNeverDecidesForThisOne() {
        // A display frame: the browser fills the left half, a notes window
        // whose top bar reads "Private" fills the right half.
        let browser = CGRect(x: 0, y: 0, width: 0.5, height: 0.9)
        let notesBadge = OCRLine(text: "Private", boundingBox: CGRect(x: 0.7, y: 0.86, width: 0.04, height: 0.01),
                                 confidence: 1)
        XCTAssertNil(BrowserPixelCapturePolicy.topBarFinding(
            [notesBadge], window: browser, pixelSize: CGSize(width: 2400, height: 1600), pixelsPerPoint: 2,
            denylist: SensitiveCaptureDenylist(entries: [])))
    }

    // MARK: - Sign-in and bank sites, from the address bar

    func testASignInOrBankAddressInTheTopBarSkipsThePage() async {
        let denylist = SensitiveCaptureDenylist(entries: [])
        for address in ["secure.chase.com", "https://accounts.google.com/v3/signin/identifier", "paypal.com/myaccount",
                        "login.microsoftonline.com"] {
            let lines = [Self.line(address, y: 0.925, width: 0.3), Self.line("Welcome back.", y: 0.5)]
            XCTAssertEqual(BrowserPixelCapturePolicy.topBarFinding(
                lines, window: Self.focusedWindow.rect, pixelSize: Self.pixelSize, pixelsPerPoint: 2,
                denylist: denylist), .deniedSite, address)
        }
        for address in ["chase.com.example.org", "news.example.com/chase.com", "example.org/notes"] {
            let lines = [Self.line(address, y: 0.925, width: 0.3)]
            XCTAssertNil(BrowserPixelCapturePolicy.topBarFinding(
                lines, window: Self.focusedWindow.rect, pixelSize: Self.pixelSize, pixelsPerPoint: 2,
                denylist: denylist), address)
        }
        // The address on the page itself is not the site.
        let article = Self.page(body: ["Our bank moved to chase.com last year.", "Nothing else changed."])
        XCTAssertNil(BrowserPixelCapturePolicy.topBarFinding(
            article, window: Self.focusedWindow.rect, pixelSize: Self.pixelSize, pixelsPerPoint: 2,
            denylist: denylist))
        let frames = await Self.drive([Self.line("secure.chase.com", y: 0.925, width: 0.3),
                                       Self.line("Account summary for checking", y: 0.5)])
        XCTAssertEqual(frames.map(Self.isTombstone), [true])
    }

    func testThePersonsOwnURLRulesApplyToTheAddressBar() {
        let denylist = SensitiveCaptureDenylist(entries: [DenylistEntry(kind: .urlPrefix, pattern: "https://intranet.example.com/")])
        XCTAssertEqual(BrowserPixelCapturePolicy.topBarFinding(
            [Self.line("intranet.example.com/wiki/plans", y: 0.925)], window: Self.focusedWindow.rect,
            pixelSize: Self.pixelSize, pixelsPerPoint: 2, denylist: denylist), .deniedSite)
    }

    func testOtherAppsNeverGetTheBrowserTopBarCheck() {
        let lines = [Self.line("Incognito", y: 0.925), Self.line("secure.chase.com", y: 0.95)]
        XCTAssertNil(Self.cascade().browserTopBarFinding(
            lines: lines, context: WorkflowContext(appBundleId: "com.apple.TextEdit"),
            window: Self.focusedWindow.rect, pixelSize: Self.pixelSize, pixelsPerPoint: 2))
    }

    // MARK: - Remembered windows

    func testAWindowSeenPrivateStaysSkippedWhenItsTopBarIsHidden() {
        let memory = PrivateBrowserWindows()
        let display = CGRect(x: 0, y: 0, width: 1200, height: 825)
        let chrome = VisibleWindow(windowId: 31, bundleId: "com.google.Chrome", title: "Release notes",
                                   bounds: CGRect(x: 0, y: 25, width: 1200, height: 800), layer: 0)
        let geometry = BackgroundCapturePolicy.geometry(of: chrome, displayBounds: display, pixelsPerPoint: 2,
                                                        windows: [chrome], excludedBundleIds: []).geometry
        let size = CGSize(width: 2400, height: 1650)
        // In the display frame the window's top bar starts just under the menu bar.
        let chip = OCRLine(text: "Incognito", boundingBox: CGRect(x: 0.86, y: 0.89, width: 0.06, height: 0.015),
                           confidence: 1)
        let body = [OCRLine(text: "The release notes cover the new reading order.",
                            boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.015), confidence: 1)]
        XCTAssertTrue(BackgroundCapturePolicy.skipsBrowserWindow(
            chrome, lines: [chip] + body, geometry: geometry, pixelSize: size,
            denylist: SensitiveCaptureDenylist(entries: []), privateWindows: memory))
        // Later another window covers the chip: the window is still skipped,
        // on the whole screen and when it is focused again.
        XCTAssertTrue(BackgroundCapturePolicy.skipsBrowserWindow(
            chrome, lines: body, geometry: geometry, pixelSize: size,
            denylist: SensitiveCaptureDenylist(entries: []), privateWindows: memory))
        let focused = FocusedWindow(bundleId: "com.google.Chrome", windowId: 31)
        XCTAssertEqual(Self.cascade(privateWindows: memory).snapshotPixelPrivacy(
            context: WorkflowContext(appBundleId: "com.google.Chrome", windowTitle: "Release notes"),
            capturedWindow: focused).decision, .suppress(reason: .denylistSource))
    }

    func testAFocusedWindowSeenPrivateStaysSkippedOnAReadWithoutItsTopBar() async {
        let memory = PrivateBrowserWindows()
        let chip = Self.line("Incognito", x: 0.86, y: 0.925, width: 0.06)
        let first = await Self.drive(Self.page(topBar: [chip]), windowId: 41, memory: memory)
        XCTAssertEqual(first.map(Self.isTombstone), [true])
        XCTAssertTrue(memory.contains(41))
        let body = Array(Self.page().dropFirst(2))
        let later = await Self.drive(body, windowId: 41, memory: memory)
        XCTAssertEqual(later.map(Self.isTombstone), [true])
        let otherWindow = await Self.drive(body, windowId: 42, memory: memory)
        XCTAssertEqual(otherWindow.map(Self.isTombstone), [false])
    }

    func testABankPageIsNotRememberedForTheWindow() {
        let memory = PrivateBrowserWindows()
        let display = CGRect(x: 0, y: 0, width: 1200, height: 825)
        let safari = VisibleWindow(windowId: 51, bundleId: "com.apple.Safari", title: "Account summary",
                                   bounds: CGRect(x: 0, y: 25, width: 1200, height: 800), layer: 0)
        let geometry = BackgroundCapturePolicy.geometry(of: safari, displayBounds: display, pixelsPerPoint: 2,
                                                        windows: [safari], excludedBundleIds: []).geometry
        let size = CGSize(width: 2400, height: 1650)
        let bank = OCRLine(text: "secure.chase.com", boundingBox: CGRect(x: 0.4, y: 0.92, width: 0.2, height: 0.015),
                           confidence: 1)
        let news = OCRLine(text: "example.org/notes", boundingBox: CGRect(x: 0.4, y: 0.92, width: 0.2, height: 0.015),
                           confidence: 1)
        XCTAssertTrue(BackgroundCapturePolicy.skipsBrowserWindow(
            safari, lines: [bank], geometry: geometry, pixelSize: size,
            denylist: SensitiveCaptureDenylist(entries: []), privateWindows: memory))
        XCTAssertFalse(memory.contains(51))
        XCTAssertFalse(BackgroundCapturePolicy.skipsBrowserWindow(
            safari, lines: [news], geometry: geometry, pixelSize: size,
            denylist: SensitiveCaptureDenylist(entries: []), privateWindows: memory))
    }

    func testTheMemoryKeepsTheMostRecentWindows() {
        let memory = PrivateBrowserWindows()
        for id in 0..<CGWindowID(PrivateBrowserWindows.capacity + 10) { memory.remember(id) }
        XCTAssertFalse(memory.contains(0))
        XCTAssertTrue(memory.contains(CGWindowID(PrivateBrowserWindows.capacity + 9)))
    }

    // MARK: - The Automation probe can only add a skip

    func testABrowserReportingAPrivateWindowIsSkippedAndNoAnswerIsRead() {
        let window = FocusedWindow(bundleId: "com.google.Chrome", windowId: 61, axRect: CGRect(x: 0, y: 25, width: 1200, height: 800))
        let context = WorkflowContext(appBundleId: "com.google.Chrome", windowTitle: "Release notes")
        XCTAssertEqual(Self.cascade(probe: AnswersPrivate(answer: true))
            .snapshotPixelPrivacy(context: context, capturedWindow: window).decision, .suppress(reason: .denylistSource))
        XCTAssertEqual(Self.cascade(probe: AnswersPrivate(answer: false))
            .snapshotPixelPrivacy(context: context, capturedWindow: window).decision, .allow)
        XCTAssertEqual(Self.cascade(probe: nil)
            .snapshotPixelPrivacy(context: context, capturedWindow: window).decision, .allow)
    }

    // MARK: - Every other gate stays as strong

    func testPasswordFieldsPasswordManagersAndSignInSitesStayNeverRead() {
        let window = FocusedWindow(bundleId: "com.apple.Safari", windowId: 71)
        let secure = SuppressionCascade(
            secureEventInput: SecureInputOn(), axSecureSubrole: NonSecureAX(),
            denylist: SensitiveCaptureDenylist(entries: []), blackedRegion: NoBlackedRegion(),
            browserAppBundles: BrowserPixelCapturePolicy.browserBundleIds, admissionPolicy: .ordinaryApplications,
            privateWindows: PrivateBrowserWindows())
        XCTAssertEqual(secure.snapshotPixelPrivacy(context: WorkflowContext(appBundleId: "com.apple.Safari"),
                                                   capturedWindow: window).decision,
                       .suppress(reason: .secureEventInput))
        let cascade = Self.cascade()
        XCTAssertEqual(cascade.decide(context: WorkflowContext(appBundleId: "com.apple.Safari",
                                                               url: "https://accounts.google.com/signin")),
                       .suppress(reason: .denylistSource))
        XCTAssertEqual(cascade.decide(context: WorkflowContext(appBundleId: "com.1password.1password")),
                       .suppress(reason: .denylistSource))
        XCTAssertEqual(cascade.decideOcr(text: "password: hunter2", context: WorkflowContext(appBundleId: "com.apple.Safari")),
                       .suppress(reason: .ocrTimeSecret))
    }

    // MARK: - Driving the emitter

    static func drive(_ lines: [OCRLine], windowId: UInt32? = nil,
                      memory: PrivateBrowserWindows = PrivateBrowserWindows()) async -> [Data] {
        let sink = BrowserRecordingSink()
        await CascadeTwiceOCREmitter.handleOCRResult(
            tsUs: 1,
            context: WorkflowContext(appBundleId: "com.google.Chrome", windowTitle: "Release notes"),
            result: OCRResult(recognizedLines: lines, durationMs: 1, timedOut: false),
            cascade: cascade(privateWindows: memory),
            sink: sink,
            sequence: FrameSequence(),
            counters: HelperHealthCounters(),
            pixelBuffer: makePixelBuffer(width: Int(pixelSize.width), height: Int(pixelSize.height)),
            evidenceCandidate: windowId.map {
                KeyframeEvidenceCandidate(captureOrdinal: 1, focusedWindowId: $0, dhash: DHash(bits: 0),
                                          monotonicNanoseconds: 1)
            },
            geometry: focusedWindow
        )
        return await sink.frames()
    }

    static func isTombstone(_ frame: Data) -> Bool {
        frame.count >= 4 && frame[2] == 0x11 && frame[3] == 0
    }

    static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var output: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil,
                                         &output) == kCVReturnSuccess)
        return output!
    }
}

private actor BrowserRecordingSink: FrameSink {
    private var recorded: [Data] = []
    func write(_ bytes: Data) throws { recorded.append(bytes) }
    func frames() -> [Data] { recorded }
}

private struct AnswersPrivate: BrowserWindowPrivacyChecking {
    let answer: Bool
    func isPrivate(for _: WorkflowContext, capturedWindow _: FocusedWindow?) -> Bool { answer }
}

private struct NoSecureInput: SecureEventInputProbe {
    func isSecureEventInputEnabled() -> Bool { false }
}

private struct SecureInputOn: SecureEventInputProbe {
    func isSecureEventInputEnabled() -> Bool { true }
}

private struct NonSecureAX: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { false }
}

private struct NoBlackedRegion: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}
