import AppKit
import CoreImage
import OnboardingKit
import SwiftUI

// Small, faithful copies of Hippocampus's own surfaces, drawn from made-up
// data (`OnboardingCopy.Demo`): Ask as it drops from the top of the screen,
// the window's Overview, and an AI tool starting a session with what
// Hippocampus shares. Setup cannot link the window's code, so the colours,
// type and shapes here copy its tokens (`MCI.Color`, `DayStripPalette`, the
// Ask panel's layout). Nothing here reads this Mac.

/// The window's own colours (RecallUIKit `MCI.Color`, light).
enum MiniPalette {
    static let canvas = rgb(0xF7F8FA)
    static let surface = Color.white
    static let border = rgb(0xE2E4E8)
    static let ink = rgb(0x1D1D1F)
    static let secondary = rgb(0x6E6E73)
    static let muted = rgb(0x8E8E93)
    static let accentText = rgb(0x0A66D8)
    static let sidebar = rgb(0xF1F2F4)
    static let selection = rgb(0xE2E4E8)
    static let strip = rgb(0xEDEFF2)
    static let panel = rgb(0xF5F5F7)
    /// The desktop the demo plays on: the tile's cool grey.
    static let desktop = rgb(0xE6EBF3)
    /// Kinds of work, as the day strip colours them (`DayStripPalette`):
    /// writing, code, meetings.
    static let kinds = [rgb(0xEB6834), rgb(0x2A78D6), rgb(0xE87BA4)]

    static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

/// An app's own icon, or a plain glyph when it is not installed. Grey
/// when the app's window is skipped: the grey is in the picture itself, so
/// it shows the same on screen and in a render.
struct AppIconImage: View {
    let bundleId: String
    var side: CGFloat = 16
    var grey = false

    var body: some View {
        Group {
            if let icon = Self.icon(for: bundleId, grey: grey) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(MiniPalette.muted)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func icon(for bundleId: String, grey: Bool = false) -> NSImage? {
        let key = grey ? "grey:" + bundleId : bundleId
        if let known = cache[key] { return known }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        var icon = NSWorkspace.shared.icon(forFile: url.path)
        if grey, let greyed = Self.greyed(icon) { icon = greyed }
        cache[key] = icon
        return icon
    }

    /// The icon without its colour, at 256 pixels.
    private static func greyed(_ icon: NSImage) -> NSImage? {
        var rect = CGRect(x: 0, y: 0, width: 256, height: 256)
        guard let source = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(CIImage(cgImage: source), forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage,
              let greyed = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: greyed, size: icon.size)
    }
}

/// A window's frame: a title bar with its three buttons, as an inactive
/// window shows them (grey), and the content below.
struct MiniWindow<Content: View>: View {
    var title: String?
    var titleBar: CGFloat = 20
    /// A toolbar button beside the window's buttons: Mail's Send.
    var toolbarSymbol: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(Color.black.opacity(0.13)).frame(width: 7, height: 7)
                    }
                    if let toolbarSymbol {
                        Image(systemName: toolbarSymbol)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(MiniPalette.muted)
                            .padding(.leading, 9)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                if let title {
                    Text(title)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(MiniPalette.secondary)
                }
            }
            .frame(height: titleBar)
            .background(MiniPalette.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(MiniPalette.border).frame(height: 0.5) }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(MiniPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 10, y: 5)
    }
}

/// The top of the demo's screen: the menu bar, with the hi mark among the
/// status items, remembering.
struct MiniMenuBar: View {
    var body: some View {
        HStack(spacing: 9) {
            Spacer(minLength: 0)
            HiMarkGlyph(letters: MiniPalette.ink, monochrome: true).frame(height: 9)
            Image(systemName: "wifi").font(.system(size: 8.5, weight: .semibold))
            Image(systemName: "battery.75percent").font(.system(size: 10))
            Text(OnboardingCopy.Demo.menuBarClock).font(.system(size: 8.5, weight: .medium))
        }
        .foregroundStyle(MiniPalette.ink.opacity(0.8))
        .padding(.horizontal, 12)
        .frame(height: 18)
        .background(Color.white.opacity(0.55))
    }
}

/// A key as Ask's footer draws it: "⌘C".
private struct MiniKey: View {
    let keys: String
    var body: some View {
        Text(keys)
            .font(.system(size: 8, weight: .medium))
            .padding(.horizontal, 3.5)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

// MARK: - Ask

/// Ask, as it drops from the top of the screen: the question, the answer,
/// and where it came from.
struct MiniAskPanel: View {
    let frame: DemoFrame
    var width: CGFloat = 400

    private var question: String {
        String(OnboardingCopy.Demo.askQuestion.prefix(frame.typedQuestion))
    }

    private var isTyping: Bool {
        frame.typedQuestion < OnboardingCopy.Demo.askQuestion.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                HiMarkGlyph().frame(height: 13)
                HStack(spacing: 1) {
                    Text(question)
                        .font(.system(size: 15))
                        .foregroundStyle(MiniPalette.ink)
                    if !frame.showsAnswer {
                        // The caret, until the question is asked.
                        Rectangle().fill(OnboardingDesign.Palette.accent).frame(width: 1.5, height: 17)
                    }
                }
                Spacer(minLength: 0)
                context
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(height: 40)

            if frame.showsAnswer {
                Divider().opacity(0.6)
                VStack(alignment: .leading, spacing: 7) {
                    Text(OnboardingCopy.Demo.askAnswer)
                        .font(.system(size: 12.5))
                        .foregroundStyle(MiniPalette.ink)
                    Text(OnboardingCopy.Demo.sourcesLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(MiniPalette.secondary)
                        .padding(.top, 2)
                    HStack(spacing: 8) {
                        AppIconImage(bundleId: "com.apple.Safari", side: 17)
                        Text(OnboardingCopy.Demo.source)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MiniPalette.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .opacity(frame.showsSource ? 1 : 0)
                    .offset(y: frame.showsSource ? 0 : 3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .transition(.opacity)
                Divider().opacity(0.6)
                HStack(spacing: 6) {
                    Text(OnboardingCopy.Demo.onThisMac)
                    Spacer(minLength: 0)
                    MiniKey(keys: OnboardingCopy.Demo.copyAnswerKeys)
                    Text(OnboardingCopy.Demo.copyAnswer)
                }
                .font(.system(size: 8.5))
                .foregroundStyle(MiniPalette.secondary)
                .padding(.horizontal, 12)
                .frame(height: 22)
            }
        }
        .frame(width: width)
        .background(MiniPalette.panel, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
    }

    /// The window Ask opened over, as the app's header names it.
    private var context: some View {
        HStack(spacing: 4) {
            AppIconImage(bundleId: MiniMessageBehind.mailBundleId, side: 11)
            Text(OnboardingCopy.Demo.askContext)
                .font(.system(size: 8.5))
                .foregroundStyle(MiniPalette.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(Color.black.opacity(0.05), in: Capsule())
        .fixedSize()
    }
}

/// The message the person is writing when they need the link. Ask drops
/// over it and finds a page read earlier, so the answer comes from memory,
/// not from the screen.
struct MiniMessageBehind: View {
    static let mailBundleId = "com.apple.mail"

    var body: some View {
        MiniWindow(title: OnboardingCopy.Demo.messageTitle, toolbarSymbol: "paperplane") {
            VStack(alignment: .leading, spacing: 0) {
                field(OnboardingCopy.Demo.messageToLabel, OnboardingCopy.Demo.messageTo)
                Divider().opacity(0.7)
                field(OnboardingCopy.Demo.messageSubjectLabel, OnboardingCopy.Demo.messageTitle)
                Divider().opacity(0.7)
                HStack(spacing: 1) {
                    Text(OnboardingCopy.Demo.messageBody)
                        .font(.system(size: 11))
                        .foregroundStyle(MiniPalette.ink)
                    // The caret: the person is mid-sentence.
                    Rectangle().fill(OnboardingDesign.Palette.accent).frame(width: 1.2, height: 13)
                }
                .padding(.top, 12)
            }
            .padding(.horizontal, 14)
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(MiniPalette.muted)
            Text(value).foregroundStyle(MiniPalette.ink)
        }
        .font(.system(size: 10))
        .frame(height: 22)
    }
}

// MARK: - Overview

/// The day strip: sessions as blocks on the day's hours, coloured by kind.
struct MiniDayStrip: View {
    var sessionsShown: Int
    var highlightsLast = false
    var height: CGFloat = 18
    var showsHours = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { proxy in
                let hours = WelcomeDemoScript.dayHours
                let span = hours.upperBound - hours.lowerBound
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(MiniPalette.strip)
                    ForEach(Array(WelcomeDemoScript.day.enumerated()), id: \.offset) { index, session in
                        let x = (session.start - hours.lowerBound) / span * proxy.size.width
                        let width = max(4, (session.end - session.start) / span * proxy.size.width - 2)
                        let shown = index < sessionsShown
                        let last = highlightsLast && index == WelcomeDemoScript.day.count - 1
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(MiniPalette.kinds[session.kind])
                            .frame(width: width, height: height - 4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(OnboardingDesign.Palette.accent, lineWidth: last && shown ? 1.5 : 0)
                                    .padding(-2)
                            )
                            .scaleEffect(x: shown ? 1 : 0.001, y: 1, anchor: .leading)
                            .opacity(shown ? 1 : 0)
                            .offset(x: x)
                    }
                }
            }
            .frame(height: height)
            if showsHours {
                HStack {
                    ForEach(Array(OnboardingCopy.Demo.hours.enumerated()), id: \.offset) { index, hour in
                        if index > 0 { Spacer(minLength: 0) }
                        Text(hour)
                    }
                }
                .font(.system(size: 7.5))
                .foregroundStyle(MiniPalette.secondary)
            }
        }
    }
}

/// The kinds the strip uses, as its legend shows them.
struct MiniLegend: View {
    var size: CGFloat = 8

    var body: some View {
        HStack(spacing: size) {
            ForEach(Array(OnboardingCopy.Demo.legend.enumerated()), id: \.offset) { index, name in
                HStack(spacing: size * 0.4) {
                    Circle().fill(MiniPalette.kinds[index]).frame(width: size * 0.7, height: size * 0.7)
                    Text(name)
                }
            }
        }
        .font(.system(size: size))
        .foregroundStyle(MiniPalette.secondary)
    }
}

/// The session the day ends on, as Overview's card shows it.
struct MiniSessionCard: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            Text(OnboardingCopy.Demo.sessionTitle)
                .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
                .foregroundStyle(MiniPalette.ink)
            Text(OnboardingCopy.Demo.sessionTime)
                .font(.system(size: compact ? 8.5 : 9))
                .foregroundStyle(MiniPalette.secondary)
            Text(OnboardingCopy.Demo.sessionLine)
                .font(.system(size: compact ? 9 : 10))
                .foregroundStyle(MiniPalette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, compact ? 1 : 2)
        }
        .padding(compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MiniPalette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MiniPalette.border, lineWidth: 0.75))
    }
}

/// The window on Overview: its sidebar, the day filling in, and the
/// session the day ends on.
struct MiniOverviewWindow: View {
    let frame: DemoFrame

    var body: some View {
        MiniWindow {
            HStack(spacing: 0) {
                sidebar
                VStack(alignment: .leading, spacing: 9) {
                    Text(OnboardingCopy.Demo.today)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MiniPalette.ink)
                    MiniDayStrip(sessionsShown: frame.sessionsShown, highlightsLast: frame.showsSessionCard)
                    MiniLegend()
                        .opacity(frame.sessionsShown > 0 ? 1 : 0)
                    MiniSessionCard()
                        .opacity(frame.showsSessionCard ? 1 : 0)
                        .offset(y: frame.showsSessionCard ? 0 : 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(MiniPalette.canvas)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HiMarkGlyph(letters: MiniPalette.ink)
                .frame(height: 13)
                .padding(.leading, 6)
                .padding(.bottom, 7)
            ForEach(Array(OnboardingCopy.Demo.places.enumerated()), id: \.offset) { index, place in
                HStack(spacing: 5) {
                    Image(systemName: ["house", "magnifyingglass", "person.crop.circle"][index])
                        .font(.system(size: 8.5))
                        .frame(width: 11)
                    Text(place).font(.system(size: 9.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(MiniPalette.ink)
                .padding(.horizontal, 6)
                .padding(.vertical, 3.5)
                .background(index == 0 ? MiniPalette.selection : .clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Circle().fill(OnboardingDesign.Palette.accent).frame(width: 5, height: 5)
                Text(OnboardingCopy.Demo.remembering)
            }
            .font(.system(size: 8))
            .foregroundStyle(MiniPalette.secondary)
            .padding(.leading, 6)
        }
        .padding(8)
        .frame(width: 100)
        .frame(maxHeight: .infinity)
        .background(MiniPalette.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(MiniPalette.border).frame(width: 0.5) }
    }
}

// MARK: - Your AI

/// What Hippocampus hands an AI tool when a session starts: a few lines
/// about your recent work.
struct MiniContextBlock: View {
    var linesShown: Int
    var size: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.45) {
            HStack(spacing: 5) {
                HiMarkGlyph().frame(height: size * 0.95)
                Text(OnboardingCopy.Demo.aiContextTitle)
                    .font(.system(size: size * 0.9, weight: .semibold))
                    .foregroundStyle(MiniPalette.secondary)
            }
            ForEach(Array(OnboardingCopy.Demo.aiContextLines.enumerated()), id: \.offset) { index, line in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1).fill(MiniPalette.border).frame(width: 2)
                    Text(line)
                        .font(.system(size: size))
                        .foregroundStyle(MiniPalette.ink)
                }
                .fixedSize(horizontal: false, vertical: true)
                .opacity(index < linesShown ? 1 : 0)
                .offset(x: index < linesShown ? 0 : -4)
            }
        }
        .padding(size * 0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OnboardingDesign.Palette.accent.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: size * 0.7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.7, style: .continuous)
            .strokeBorder(OnboardingDesign.Palette.accent.opacity(0.18), lineWidth: 0.75))
    }
}

/// An AI tool starting a session in a project: it begins with what
/// Hippocampus shares, then answers from it.
struct MiniAIWindow: View {
    let frame: DemoFrame

    private var prompt: String {
        String(OnboardingCopy.Demo.aiPrompt.prefix(frame.typedPrompt))
    }

    var body: some View {
        MiniWindow(title: OnboardingCopy.Demo.aiWindowTitle) {
            VStack(alignment: .leading, spacing: 10) {
                MiniContextBlock(linesShown: frame.contextLinesShown)
                    .opacity(frame.contextLinesShown > 0 ? 1 : 0)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("›")
                        .foregroundStyle(MiniPalette.secondary)
                    Text(prompt)
                        .foregroundStyle(MiniPalette.ink)
                    if frame.typedPrompt > 0, !frame.showsReply {
                        Rectangle().fill(MiniPalette.ink.opacity(0.7)).frame(width: 6, height: 12)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .opacity(frame.contextLinesShown > 1 ? 1 : 0)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    // The reply, marked as the tool's own.
                    Circle().fill(OnboardingDesign.Palette.accent).frame(width: 6, height: 6)
                    Text(OnboardingCopy.Demo.aiReply)
                        .foregroundStyle(MiniPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11, design: .monospaced))
                .opacity(frame.showsReply ? 1 : 0)
                .offset(y: frame.showsReply ? 0 : 3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}
