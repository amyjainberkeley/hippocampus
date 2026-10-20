#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

/// The window's frame in pictures (SPEC 8.2 lane A with SPEC-DELTA 1 and 2):
/// the sidebar on day one, a week in, paused, with names hidden, narrow and
/// short; its little screenshots and the preview on hover; the status menu,
/// the banner, forgetting, the one-time lines and the key sheet; light and
/// dark. Sam's made-up week; nothing here is real.
extension WindowRenderer {
    static var shellScenes: [Scene] {
        var scenes: [Scene] = []
        for dark in [false, true] {
            let tail = dark ? "-dark" : "-light"
            scenes += [
                Scene.shell("nav-window-today" + tail, place: .today, dark: dark),
                Scene.shell("nav-sidebar-day-one" + tail, place: .today, dark: dark, understanding: .firstDay,
                      firstDay: true, work: .empty, kinds: [.webPages]),
                Scene.shell("nav-sidebar-week" + tail, dark: dark, history: true) { await $0.history.reload() },
                Scene.shell("nav-sidebar-paused" + tail, place: .today, dark: dark,
                      status: ShellRenderFixture.paused()),
                Scene.shell("nav-sidebar-hidden" + tail, place: .today, dark: dark,
                      preset: WindowShellPreset(choices: SidebarHides.Choices(workingOnHidden: true))),
                Scene.shell("nav-sidebar-hover" + tail, place: .today, dark: dark,
                      preset: WindowShellPreset(hoveredItem: ShellRenderFixture.pricingId)),
                Scene.shell("nav-status-menu" + tail, place: .today, dark: dark,
                      preset: WindowShellPreset(statusMenu: .footer, statusMenuPauseOpen: true)),
                Scene.shell("nav-status-menu-paused" + tail, place: .today, dark: dark,
                      status: ShellRenderFixture.paused(), preset: WindowShellPreset(statusMenu: .footer)),
                Scene.shell("nav-banner-permission" + tail, place: .today, dark: dark,
                      status: ShellRenderFixture.needsPermission()),
                Scene.shell("nav-forget-recent" + tail, place: .today, dark: dark,
                      preset: WindowShellPreset(forgetSheet: .tenMinutes)),
                Scene.shell("nav-narrow" + tail, dark: dark, size: CGSize(width: 820, height: 720), history: true) {
                    await $0.history.reload()
                },
                Scene.shell("nav-narrow-sidebar-open" + tail, place: .today, dark: dark,
                      size: CGSize(width: 820, height: 720),
                      preset: WindowShellPreset(narrowSidebarOpen: true)),
            ]
        }
        scenes += [
            Scene.shell("nav-status-menu-himark", place: .today, preset: WindowShellPreset(statusMenu: .hiMark)),
            Scene.shell("nav-banner-paused", dark: false, history: true, status: ShellRenderFixture.paused()) {
                await $0.history.reload()
            },
            Scene.shell("nav-banner-timed", place: .today, status: ShellRenderFixture.paused(timed: true)),
            Scene.shell("nav-banner-off", place: .today, status: ShellRenderFixture.off()),
            Scene.shell("nav-banner-not-running", place: .today,
                  status: WindowStatus(byHand: nil, appRunning: false)),
            Scene.shell("nav-opened-by-hand", place: .today,
                  status: WindowStatus(byHand: ShellRenderFixture.freshReceipt(), appRunning: true),
                  preset: WindowShellPreset(statusMenu: .footer)),
            Scene.shell("nav-forget-today", place: .today, preset: WindowShellPreset(forgetSheet: .today)),
            Scene.shell("nav-forget-undo", history: true,
                  prepare: { await $0.history.reload() },
                  note: { notes in
                      notes.show(NavigationCopy.forgotMoments(2), detail: NavigationCopy.firstForget,
                                 action: BottomNote.Action(title: NavigationCopy.undoAction) {})
                  }),
            Scene.shell("nav-short", place: .today, size: CGSize(width: 1100, height: 480)),
            Scene.shell("nav-sidebar-collapsed", place: .today, preset: WindowShellPreset(sidebarHidden: true)),
            Scene.shell("nav-new-sidebar-line", place: .today, preset: WindowShellPreset(showsNewSidebarLine: true)),
            Scene.shell("nav-working-on-footnote", place: .today, preset: WindowShellPreset(showsFootnote: true)),
            Scene.shell("nav-about-you", place: .aboutYou),
            // Privacy's page reads the activity log on this Mac, so a
            // picture shows its frame with the page left out.
            Scene.shell("nav-privacy-paused", place: .privacy, status: ShellRenderFixture.paused()),
            Scene.shell("nav-demo-memory", place: .today, demoMemory: true),
            Scene.picture("nav-keyboard-shortcuts", size: CGSize(width: 620, height: 560)) {
                AnyView(KeyboardShortcutsSheet(registry: ActionPanelRegistry()))
            },
            Scene.picture("nav-keyboard-shortcuts-dark", size: CGSize(width: 620, height: 560), dark: true) {
                AnyView(KeyboardShortcutsSheet(registry: ActionPanelRegistry()))
            },
            // The sheet scrolled to its end: Actions and Help.
            Scene.picture("nav-keyboard-shortcuts-end", size: CGSize(width: 620, height: 560)) {
                AnyView(KeyboardShortcutsSheet(registry: ActionPanelRegistry(), opensAt: .bottom))
            },
        ]
        return scenes
    }
}

extension WindowRenderer.Scene {
    /// A window scene with the shell's own settings.
    static func shell(_ name: String, place: MemoryWorkspaceSelection = .ask, dark: Bool = false,
                      understanding: PreviewUnderstandingReader.Scenario = .populated,
                      size: CGSize = CGSize(width: 1100, height: 720), firstDay: Bool = false, history: Bool = false,
                      demoMemory: Bool = false, status: WindowStatus? = nil, work: WorkSnapshot? = nil,
                      kinds: Set<SidebarPlace>? = nil, preset: WindowShellPreset = WindowShellPreset(),
                      prepare: @escaping @MainActor (AskViewModel) async -> Void = { _ in },
                      note: (@MainActor (BottomNotes) -> Void)? = nil) -> Self {
        var scene = Self(name: name, place: place, dark: dark, understanding: understanding, size: size,
                         firstDay: firstDay, history: history, demoMemory: demoMemory, prepare: prepare)
        scene.status = status
        scene.work = work
        scene.kinds = kinds
        scene.preset = preset
        scene.note = note
        return scene
    }
}

/// Sam's Working On a week in, with each item's newest kept screenshot
/// drawn, sealed and opened the way the app opens the person's own.
@MainActor
final class ShellRenderFixture {
    static let trailheadId = "w_trailhead_shop"
    static let pricingId = "w_pricing_v3"
    static let q4Id = "w_q4_planning"
    static let checklistId = "w_launch_checklist"
    static let draftId = "w_pricing_draft"

    /// The moments whose screenshots are the items' pictures.
    private static let moments: [String: UInt64] = [
        trailheadId: 72_001, pricingId: 72_002, q4Id: 72_003, checklistId: 72_004, draftId: 72_005,
    ]

    let screenshots: CountingScreenshots
    let pictures: SidebarPictures
    private let store: SyntheticScreenshotStore

    init() throws {
        let store = try SyntheticScreenshotStore()
        let drawn: [UInt64: Data?] = [
            72_001: SyntheticScreens.jpeg(.editor),
            72_002: Self.design(),
            72_003: SyntheticScreens.jpeg(.document),
            72_004: Self.notes(title: "Launch checklist", lines: [
                "Rounding fix merged", "Changelog updated", "Gift card copy reviewed", "Pricing page live",
                "Email the beta list",
            ], done: 3),
            72_005: Self.notes(title: "Pricing page draft", lines: [
                "Hero: One plan for every team", "Start free, then $18 a seat", "Compare plans",
                "Questions people ask", "Footer with the install line",
            ], done: 0),
        ]
        var paths: [UInt64: String] = [:]
        for (moment, image) in drawn {
            guard let image else { continue }
            paths[moment] = try store.seal(image)
        }
        self.store = store
        let screenshots = CountingScreenshots(store.provider())
        self.screenshots = screenshots
        let known = paths
        pictures = SidebarPictures(url: { moment in
            known[moment].map { URL(fileURLWithPath: $0) }
        }, provider: screenshots)
    }

    func remove() {
        store.remove()
    }

    /// Sam a week in (SPEC 2.12): five items in the sidebar, three more on
    /// Show All, made from window titles.
    static func weekIn(now: Date) -> WorkSnapshot {
        let nowUs = UInt64(now.timeIntervalSince1970 * 1_000_000)
        func ago(_ minutes: Double) -> UInt64 { nowUs - UInt64(minutes * 60_000_000) }
        func day(_ days: Double) -> UInt64 { nowUs - UInt64(days * 86_400_000_000) }
        let items = [
            WorkItem(id: trailheadId, kind: .code, name: "trailhead-shop",
                     apps: ["com.microsoft.VSCode", "com.apple.Terminal"], lastUs: ago(17), weekMinutes: 160,
                     daysThisWeek: 3, moments: [72_001], thumbnailMoment: moments[trailheadId]),
            WorkItem(id: pricingId, kind: .design, name: "Trailhead pricing v3", apps: ["com.figma.Desktop"],
                     lastUs: ago(51), weekMinutes: 115, daysThisWeek: 2, moments: [72_002],
                     thumbnailMoment: moments[pricingId]),
            WorkItem(id: q4Id, kind: .document, name: "Q4 planning", apps: ["com.google.Chrome"],
                     lastUs: ago(38), weekMinutes: 90, daysThisWeek: 3, moments: [72_003],
                     thumbnailMoment: moments[q4Id]),
            WorkItem(id: checklistId, kind: .document, name: "Launch checklist", apps: ["com.apple.Notes"],
                     lastUs: ago(63), weekMinutes: 70, daysThisWeek: 2, moments: [72_004],
                     thumbnailMoment: moments[checklistId]),
            WorkItem(id: draftId, kind: .document, name: "Pricing page draft", apps: ["com.apple.Notes"],
                     lastUs: ago(239), weekMinutes: 55, daysThisWeek: 1, moments: [72_005],
                     thumbnailMoment: moments[draftId]),
            WorkItem(id: "w_october_invoices", kind: .spreadsheet, name: "October invoices",
                     apps: ["com.apple.iWork.Numbers"], lastUs: ago(323), weekMinutes: 35, daysThisWeek: 1),
            WorkItem(id: "w_bike_api", kind: .code, name: "bike-api", apps: ["com.todesktop.230313mzl4w4u92"],
                     lastUs: day(10), weekMinutes: 0, daysThisWeek: 0, inSidebar: false),
            WorkItem(id: "w_pricing_v2", kind: .design, name: "Trailhead pricing v2", apps: ["com.figma.Desktop"],
                     lastUs: day(11), weekMinutes: 0, daysThisWeek: 0, inSidebar: false),
        ]
        return WorkSnapshot(generatedUs: nowUs, items: items)
    }

    // MARK: Statuses, as the app would push them

    static func remembering(now: Date) -> WindowStatus {
        WindowStatus(kind: .remembering, title: NavigationCopy.remembering, detail: "Last saved 12s ago",
                     action: .pause)
    }

    static func paused(timed: Bool = false) -> WindowStatus {
        let now = PreviewUnderstandingReader.sampleNow
        if timed {
            let until = now.addingTimeInterval(55 * 60)
            return WindowStatus(kind: .paused, title: "Paused", detail: "Until 3:32 PM.", action: .resumeNow,
                                pausedSince: now.addingTimeInterval(-5 * 60), pausedUntil: until)
        }
        return WindowStatus(kind: .paused, title: "Paused", detail: "Since 2:31 PM.", action: .resume,
                            pausedSince: now.addingTimeInterval(-6 * 60))
    }

    static func needsPermission() -> WindowStatus {
        var status = WindowStatus(kind: .needsPermission, title: "Needs permission",
                                  detail: "Screen Recording is off for Hippocampus.",
                                  action: .openSystemSettings(.screenRecording))
        status.permission = .screenRecording
        return status
    }

    static func off() -> WindowStatus {
        WindowStatus(kind: .off, title: "Off", action: .turnOn)
    }

    static func freshReceipt() -> CaptureHealthReceipt? {
        let stamp = ISO8601DateFormatter().string(from: PreviewUnderstandingReader.sampleNow)
        return try? CaptureHealthReceipt.decode(Data("""
            {"schema_version": 1, "updated_at": "\(stamp)", "last_stored_frame_at": "\(stamp)",
             "stored_frame_count": 10, "stored_screenshot_count": 2}
            """.utf8))
    }

    // MARK: Drawn screens

    /// A design tool's window: layers, the canvas and a pricing frame.
    static func design() -> Data? {
        drawn { width, height in
            fill(CGRect(x: 0, y: 0, width: width, height: 44), 0x2C2C2C)
            for (index, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                hexColor(UInt32(color)).setFill()
                NSBezierPath(ovalIn: CGRect(x: 16 + CGFloat(index) * 20, y: 16, width: 12, height: 12)).fill()
            }
            text("Trailhead pricing v3", x: width / 2 - 80, y: 13, size: 14, color: 0xFFFFFF)
            fill(CGRect(x: 0, y: 44, width: 240, height: height - 44), 0xFFFFFF)
            fill(CGRect(x: width - 260, y: 44, width: 260, height: height - 44), 0xFFFFFF)
            fill(CGRect(x: 240, y: 44, width: width - 500, height: height - 44), 0xE5E5E5)
            for (row, layer) in ["Pricing", "Hero", "Plans", "Plan card", "Plan card", "Plan card", "FAQ",
                                 "Footer"].enumerated() {
                text(layer, x: 24 + (row > 2 && row < 6 ? 16 : 0), y: 68 + CGFloat(row) * 30, size: 13,
                     color: 0x333333)
            }
            let frame = CGRect(x: 330, y: 100, width: width - 680, height: height - 160)
            fill(frame, 0xFFFFFF)
            text("One plan for every team", x: frame.minX + 60, y: frame.minY + 50, size: 34, weight: .bold,
                 color: 0x111111)
            text("Start free, then $18 a seat.", x: frame.minX + 60, y: frame.minY + 104, size: 18,
                 color: 0x555555)
            let cardWidth = (frame.width - 160) / 3
            for index in 0..<3 {
                let card = CGRect(x: frame.minX + 60 + CGFloat(index) * (cardWidth + 20), y: frame.minY + 170,
                                  width: cardWidth, height: frame.height - 240)
                let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
                hexColor(index == 1 ? 0xEEF3FF : 0xF6F6F8).setFill()
                path.fill()
                text(["Starter", "Team", "Business"][index], x: card.minX + 24, y: card.minY + 28, size: 18,
                     weight: .semibold, color: 0x222222)
                text(["Free", "$18", "$32"][index], x: card.minX + 24, y: card.minY + 64, size: 30,
                     weight: .bold, color: 0x111111)
                for line in 0..<4 {
                    fill(CGRect(x: card.minX + 24, y: card.minY + 130 + CGFloat(line) * 28, width: card.width - 80,
                                height: 9), 0xD5D8DE)
                }
                let button = NSBezierPath(roundedRect: CGRect(x: card.minX + 24, y: card.maxY - 64,
                                                              width: card.width - 48, height: 40),
                                          xRadius: 8, yRadius: 8)
                hexColor(index == 1 ? 0x2F6BFF : 0xDDE2EA).setFill()
                button.fill()
            }
            for line in 0..<10 {
                fill(CGRect(x: width - 240, y: 70 + CGFloat(line) * 34, width: 180, height: 10), 0xE4E6EA)
            }
        }
    }

    /// A notes window: the folder list, then a note with its lines.
    static func notes(title: String, lines: [String], done: Int) -> Data? {
        drawn { width, height in
            fill(CGRect(x: 0, y: 0, width: width, height: height), 0xFFFFFF)
            fill(CGRect(x: 0, y: 0, width: 230, height: height), 0xF0F0F2)
            fill(CGRect(x: 230, y: 0, width: 300, height: height), 0xF8F8F9)
            for (index, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                hexColor(UInt32(color)).setFill()
                NSBezierPath(ovalIn: CGRect(x: 18 + CGFloat(index) * 20, y: 18, width: 12, height: 12)).fill()
            }
            for (row, folder) in ["iCloud", "Notes", "Launch", "Pricing", "Recently Deleted"].enumerated() {
                text(folder, x: 24, y: 64 + CGFloat(row) * 30, size: 13, weight: row == 0 ? .semibold : .regular,
                     color: 0x333333)
            }
            for row in 0..<6 {
                fill(CGRect(x: 250, y: 64 + CGFloat(row) * 64, width: 200, height: 11), 0xD9DBE0)
                fill(CGRect(x: 250, y: 84 + CGFloat(row) * 64, width: 150, height: 9), 0xE6E8EC)
            }
            text(title, x: 580, y: 70, size: 30, weight: .bold, color: 0x1D1D1F)
            for (row, line) in lines.enumerated() {
                let y = 140 + CGFloat(row) * 40
                let circle = NSBezierPath(ovalIn: CGRect(x: 580, y: y, width: 20, height: 20))
                if row < done {
                    hexColor(0x2F6BFF).setFill()
                    circle.fill()
                } else {
                    hexColor(0xB8BCC4).setStroke()
                    circle.lineWidth = 1.5
                    circle.stroke()
                }
                text(line, x: 614, y: y - 1, size: 17, color: row < done ? 0x8E8E93 : 0x1D1D1F)
            }
        }
    }

    private static func drawn(_ draw: (CGFloat, CGFloat) -> Void) -> Data? {
        let width = Int(SyntheticScreens.size.width)
        let height = Int(SyntheticScreens.size.height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        // Top-left origin, as a window is laid out.
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        draw(CGFloat(width), CGFloat(height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86])
    }

    private static func fill(_ rect: CGRect, _ color: UInt32) {
        hexColor(color).setFill()
        rect.fill()
    }

    private static func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat,
                             weight: NSFont.Weight = .regular, color: UInt32) {
        (string as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: hexColor(color),
        ])
    }
}
/// A colour from its hex value, for the drawn screens.
func hexColor(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}
#endif
