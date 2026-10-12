import AppKit
import ApplicationServices
import HippocampusKit
import SwiftUI

// MARK: Controller

/// Owns the command bar panel. ⌃⇧Space toggles it over whatever app is in
/// front; it never activates Hippocampus or opens a window of its own.
@MainActor
final class CommandBarController: NSObject, NSWindowDelegate {
    static let shared = CommandBarController()

    private var panel: CommandBarPanel?
    private var model: CommandBarModel?
    private var openEvent: ((UInt64) -> Void)?
    private var topEdge: CGFloat = 0

    func configure(model: CommandBarModel, openEvent: @escaping (UInt64) -> Void) {
        self.model = model
        self.openEvent = openEvent
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show(asking question: String? = nil) {
        guard let model else { return }
        model.opened(context: Self.frontmostContext())
        if let question {
            model.query = question
            model.ask(question)
        }
        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        place(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        // Opened from a link, the app was activated; give focus back to the
        // app the person was in, unless a Hippocampus window is in use.
        if NSApp.isActive,
           !NSApp.windows.contains(where: { $0.isVisible && !($0 is CommandBarPanel) && $0.canBecomeMain }) {
            NSApp.hide(nil)
        }
    }

    private func makePanel(model: CommandBarModel) -> CommandBarPanel {
        let panel = CommandBarPanel()
        panel.onCancel = { [weak self, weak model] in
            if model?.back() != true { self?.hide() }
        }
        let view = CommandBarView(
            model: model,
            perform: { [weak self] action in self?.perform(action) },
            close: { [weak self] in self?.hide() },
            heightChanged: { [weak self] height in self?.resize(height: height) }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.delegate = self
        return panel
    }

    private func place(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let width = CommandBarView.width
        let height = max(panel.frame.height, CommandBarView.searchHeight)
        topEdge = visible.maxY - visible.height * 0.22
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: topEdge - height, width: width, height: height), display: true)
    }

    private func resize(height: CGFloat) {
        guard let panel, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = (topEdge > 0 ? topEdge : frame.maxY) - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
    }

    private func perform(_ action: BarAction) {
        hide()
        switch action {
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .openEvent(let id):
            openEvent?(id)
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    /// The app in front, and its focused window's title when Accessibility
    /// allows reading it. Hippocampus's own windows are not context.
    static func frontmostContext() -> FrontmostContext? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return nil }
        var title: String?
        if AXIsProcessTrusted() {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.15)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                var value: CFTypeRef?
                // swiftlint:disable:next force_cast
                if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value) == .success {
                    title = (value as? String).flatMap { $0.isEmpty ? nil : $0 }
                }
            }
        }
        return FrontmostContext(bundleId: app.bundleIdentifier, appName: app.localizedName, windowTitle: title)
    }
}

/// A borderless, non-activating panel that takes keyboard focus without
/// taking it from the app you are in, like Spotlight.
final class CommandBarPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: CommandBarView.width, height: CommandBarView.searchHeight),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc anywhere in the panel, even when the field has lost focus.
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: Views

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct CommandBarView: View {
    static let width: CGFloat = 700
    static let searchHeight: CGFloat = 60
    static let corner: CGFloat = 22

    @ObservedObject var model: CommandBarModel
    let perform: (BarAction) -> Void
    let close: () -> Void
    let heightChanged: (CGFloat) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            if hasBody {
                Divider().opacity(0.6)
                content
                    .frame(maxHeight: 520)
                Divider().opacity(0.6)
                footer
            }
        }
        .frame(width: Self.width)
        .background(GeometryReader { proxy in Color.clear.preference(key: HeightKey.self, value: proxy.size.height) })
        .modifier(GlassBackground(corner: Self.corner))
        .onPreferenceChange(HeightKey.self) { height in heightChanged(height) }
        .onAppear { focused = true }
        .onChange(of: model.mode) { _, _ in focused = true }
        .onChange(of: model.focusRequest) { _, _ in
            // After the panel becomes key; a focus set before that is lost.
            DispatchQueue.main.async { focused = true }
        }
    }

    private var hasBody: Bool {
        !model.rows.isEmpty || model.mode == .answer || model.mode == .day || model.mode == .model || model.notice != nil
    }

    // Search row

    private var searchRow: some View {
        HStack(spacing: 12) {
            CurlGlyph()
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($focused)
                .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                .onKeyPress(.escape) {
                    if !model.back() { close() }
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    if let action = model.activate(preferAsk: press.modifiers.contains(.command)) { perform(action) }
                    return .handled
                }
                .onKeyPress(characters: ["d", "c", "u"], phases: .down) { press in
                    if press.modifiers.contains(.command), press.characters == "d" {
                        model.showDay()
                        return .handled
                    }
                    if press.modifiers.contains(.command), press.characters == "u" {
                        model.showModel()
                        return .handled
                    }
                    if press.modifiers.contains([.command, .shift]), press.characters.lowercased() == "c" {
                        Task {
                            if let text = await model.copyContext() { perform(.copy(text)) }
                        }
                        return .handled
                    }
                    return .ignored
                }
            if model.isWorking {
                ProgressView().controlSize(.small)
            }
            if let context = model.context, let name = context.appName {
                ContextChip(bundleId: context.bundleId, name: name, title: context.windowTitle)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: Self.searchHeight)
    }

    private var placeholder: String {
        "Ask or search your memory"
    }

    // Content

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .day:
            ScrollView { DayCard(day: model.day) }
        case .model:
            ScrollView {
                ModelCard(propositions: model.propositions, working: model.isWorking) { id, right in
                    model.judge(id, right: right)
                }
            }
        case .answer:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    AnswerCard(question: model.askedQuestion ?? "", answer: model.answer, working: model.isWorking)
                    if !model.rows.isEmpty {
                        SectionHeader(title: "From your memory")
                        rowList
                    }
                }
            }
        default:
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let notice = model.notice, model.rows.isEmpty {
                            Text(notice).font(.callout).foregroundStyle(.secondary).padding(16)
                        }
                        if model.mode == .home, !model.rows.isEmpty {
                            SectionHeader(title: "Suggested for right now")
                        }
                        rowList
                    }
                    .padding(.bottom, 6)
                }
                .onChange(of: model.selection) { _, index in
                    if model.rows.indices.contains(index) {
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(model.rows[index].id) }
                    }
                }
            }
        }
    }

    private var rowList: some View {
        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
            if model.mode == .results, index == 1 {
                SectionHeader(title: "From your memory")
            }
            BarRowView(row: row, selected: index == model.selection)
                .id(row.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.select(index)
                    if let action = model.activate() { perform(action) }
                }
                .onHover { inside in if inside { model.select(index) } }
        }
    }

    // Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Text("Hippocampus").font(.caption).foregroundStyle(.tertiary)
            Text("On this Mac").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            switch model.mode {
            case .home:
                KeyHint(keys: "↩", label: "Open")
                KeyHint(keys: "⌘D", label: "Your day")
                KeyHint(keys: "⌘U", label: "About you")
            case .results:
                KeyHint(keys: "↩", label: "Open")
                KeyHint(keys: "⌘↩", label: "Ask")
                KeyHint(keys: "⇧⌘C", label: "Copy context")
            case .answer, .day, .model:
                KeyHint(keys: "esc", label: "Back")
                KeyHint(keys: "⇧⌘C", label: "Copy context")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }
}

/// Liquid Glass on macOS 26; the native HUD material before it.
private struct GlassBackground: ViewModifier {
    let corner: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        } else {
            content
                .background(VisualEffect())
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.white.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The curl mark, drawn from the same golden-ratio arcs as the app icon.
struct CurlGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                CurlShape().stroke(style: StrokeStyle(lineWidth: side * 0.125, lineCap: .round))
                CurlDot()
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Quarter arcs whose radii shrink by the golden ratio, in a unit box.
struct CurlShape: Shape {
    static func geometry() -> (path: Path, end: CGPoint, radius: CGFloat) {
        var path = Path()
        var center = CGPoint(x: 0.465, y: 0.545)
        var radius: CGFloat = 0.385
        var angle: CGFloat = -.pi / 4
        path.move(to: CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
        for _ in 0..<5 {
            let next = angle - .pi / 2
            path.addArc(center: center, radius: radius, startAngle: .radians(angle), endAngle: .radians(next), clockwise: true)
            let end = CGPoint(x: center.x + radius * cos(next), y: center.y + radius * sin(next))
            let smaller = radius / 1.618
            center = CGPoint(x: end.x + (center.x - end.x) * smaller / radius, y: end.y + (center.y - end.y) * smaller / radius)
            radius = smaller
            angle = next
        }
        return (path, center, radius)
    }

    func path(in rect: CGRect) -> Path {
        Self.geometry().path.applying(CGAffineTransform(scaleX: rect.width, y: rect.height))
    }
}

private struct CurlDot: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CurlShape.geometry().end
        let r: CGFloat = 0.075
        return Path(ellipseIn: CGRect(x: (center.x - r) * rect.width, y: (center.y - r) * rect.height,
                                      width: 2 * r * rect.width, height: 2 * r * rect.height))
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label).font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

private struct ContextChip: View {
    let bundleId: String?
    let name: String
    let title: String?
    var body: some View {
        HStack(spacing: 6) {
            AppIcon(bundleId: bundleId).frame(width: 16, height: 16)
            Text(title.map { "\(name) · \($0)" } ?? name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 220)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .foregroundStyle(.secondary)
        .help("Hippocampus knows what you’re looking at")
    }
}

private struct AppIcon: View {
    let bundleId: String?
    var body: some View {
        if let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
        } else {
            Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }
}

private struct BarRowView: View {
    let row: BarRow
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(.tertiary)
            }
            if selected {
                Text("↩").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.09) : .clear)
        )
        .padding(.horizontal, 6)
    }

    @ViewBuilder private var icon: some View {
        switch row {
        case .hit(let hit): AppIcon(bundleId: hit.appBundleId)
        case .source: Image(systemName: "quote.opening").font(.system(size: 15)).foregroundStyle(.secondary)
        case .ask: Image(systemName: "sparkles").font(.system(size: 17)).foregroundStyle(.tint)
        case .suggestion(let s):
            Image(systemName: Self.symbol(for: s.kind)).font(.system(size: 16)).foregroundStyle(s.kind == "predicted" ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }

    static func symbol(for kind: String) -> String {
        switch kind {
        case "resume": "arrow.uturn.backward.circle"
        case "searched": "magnifyingglass"
        case "related": "link"
        case "day": "chart.bar.xaxis"
        case "model": "person.crop.circle"
        default: "sparkles"
        }
    }

    private var title: String {
        switch row {
        case .hit(let hit): hit.windowTitle?.isEmpty == false ? hit.windowTitle! : (hit.body.isEmpty ? "Untitled" : hit.body)
        case .source(let s): s.title?.isEmpty == false ? s.title! : s.app
        case .ask(let q): "Ask Hippocampus: “\(q)”"
        case .suggestion(let s): s.title
        }
    }

    private var subtitle: String? {
        switch row {
        case .hit(let hit): hit.body
        case .source(let s): "\(s.app) · \(s.text.split(separator: "\n").dropFirst().joined(separator: " "))"
        case .ask: "Answers from what you’ve seen, on this Mac"
        case .suggestion(let s): s.why
        }
    }

    private var trailing: String? {
        switch row {
        case .hit(let hit): Self.relative(hit.tsUs)
        case .source(let s): Self.relative(s.tsUs)
        default: nil
        }
    }

    static func relative(_ tsUs: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(tsUs) / 1_000_000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct AnswerCard: View {
    let question: String
    let answer: BarAnswer?
    let working: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = answer?.answer {
                Text(text)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking on your Mac…").font(.callout).foregroundStyle(.secondary)
                }
            } else if let reason = answer?.unavailable {
                Text(Self.explain(reason)).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func explain(_ reason: String) -> String {
        switch reason {
        case "apple_intelligence_off": "Turn on Apple Intelligence in System Settings to get answers. Here’s what Hippocampus found:"
        case "device_not_eligible", "not_installed", "cannot_launch": "Answers need macOS 26 with Apple Intelligence. Here’s what Hippocampus found:"
        case "model_not_ready": "Apple Intelligence is still getting ready. Here’s what Hippocampus found:"
        default: "Here’s what Hippocampus found:"
        }
    }
}

private struct DayCard: View {
    let day: BarDay?

    var body: some View {
        if let day {
            let b = day.day.breakdown
            VStack(alignment: .leading, spacing: 14) {
                if let n = day.day.narrative {
                    Text(n.headline).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if day.day.writtenBy != "measured" {
                        Text(n.narrative).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 22) {
                    Metric(value: Self.hours(b.activeUs), label: b.basis == "measured" ? "Active" : "Active (est.)")
                    Metric(value: Self.hours(b.focusBlocks.map { $0.endUs - $0.startUs }.max() ?? 0), label: "Longest focus")
                    Metric(value: String(format: "%.0f", b.switchesPerHour), label: "Switches / hr")
                    Metric(value: "\(b.searches.count)", label: "Searches")
                }
                KindBar(kinds: b.kinds)
                if let n = day.day.narrative, !n.insights.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(n.insights, id: \.self) { insight in
                            Label(insight, systemImage: "circle.fill")
                                .labelStyle(BulletLabel())
                                .font(.callout)
                        }
                        if !n.suggestion.isEmpty {
                            Label(n.suggestion, systemImage: "arrow.forward")
                                .font(.callout)
                                .foregroundStyle(.tint)
                        }
                    }
                }
                if !b.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sessions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(b.sessions.suffix(8), id: \.startUs) { session in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(Self.clock(session.startUs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(session.title).font(.callout.weight(.medium)).lineLimit(1)
                                }
                                if session.beneath != "Nothing notable." {
                                    Text(session.beneath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
                if !b.searches.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("You looked up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        FlowChips(items: b.searches.prefix(12).map(\.query))
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading your day…").font(.callout).foregroundStyle(.secondary)
            }
            .padding(18)
        }
    }

    static func hours(_ us: UInt64) -> String {
        let minutes = Int(us / 60_000_000)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func clock(_ us: UInt64) -> String {
        Date(timeIntervalSince1970: TimeInterval(us) / 1_000_000).formatted(date: .omitted, time: .shortened)
    }
}

/// What Hippocampus has learned about you, each claim with a confidence and
/// a way to say it is right or wrong.
private struct ModelCard: View {
    let propositions: [BarProposition]
    let working: Bool
    let judge: (Int64, Bool) -> Void
    @State private var confirmed: Set<Int64> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What Hippocampus has learned about you")
                .font(.system(size: 15, weight: .semibold))
            Text("Learned on this Mac from what you did. Mark what’s wrong and it won’t come back.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if propositions.isEmpty {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Nothing yet. Hippocampus learns from finished stretches of work.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(propositions) { proposition in
                HStack(alignment: .top, spacing: 10) {
                    Text(proposition.kind.capitalized)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.7), in: Capsule())
                        .foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(proposition.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text(confirmed.contains(proposition.id) ? "You confirmed this" : "\(Int((proposition.confidence * 100).rounded()))% sure · \(proposition.evidence.count) \(proposition.evidence.count == 1 ? "moment" : "moments")")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        confirmed.insert(proposition.id)
                        judge(proposition.id, true)
                    } label: { Image(systemName: "checkmark") }
                        .buttonStyle(.borderless)
                        .help("That’s right")
                        .disabled(confirmed.contains(proposition.id))
                    Button { judge(proposition.id, false) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("That’s wrong: forget it")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(.secondary).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Metric: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 18, weight: .semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct KindBar: View {
    let kinds: [BarDay.Kind]

    static func color(_ kind: String) -> Color {
        switch kind {
        case "code": .blue
        case "writing": .indigo
        case "research": .teal
        case "communication": .orange
        case "meetings": .pink
        case "design": .purple
        case "ai": .mint
        case "planning": .yellow
        case "media": .red
        default: .gray
        }
    }

    var body: some View {
        let total = max(kinds.reduce(0) { $0 + $1.activeUs }, 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(kinds, id: \.kind) { kind in
                        Self.color(kind.kind)
                            .frame(width: max(2, proxy.size.width * CGFloat(kind.activeUs) / CGFloat(total) - 2))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            HStack(spacing: 12) {
                ForEach(kinds.prefix(5), id: \.kind) { kind in
                    HStack(spacing: 4) {
                        Circle().foregroundStyle(Self.color(kind.kind)).frame(width: 7, height: 7)
                        Text("\(kind.label) \(DayCard.hours(kind.activeUs))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct FlowChips: View {
    let items: [String]
    var body: some View {
        // A simple wrapping layout for short chips.
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.7), in: Capsule())
            }
        }
    }
}

private struct WrapLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
