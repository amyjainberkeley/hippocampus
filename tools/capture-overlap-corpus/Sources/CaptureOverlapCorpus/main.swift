import AppKit

private enum CorpusContent {
    static let focusedToken = "FOCUSED_EVIDENCE_ZEPHYR_9241"
    static let backgroundToken = "BACKGROUND_SECRET_NEBULA_7713"
    static let focusControlToken = "FOCUS_REBIND_CONTROL_3087"
}

@MainActor
private final class CorpusAppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var focusChurnTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--background-only") {
            let background = makeWindow(
                title: "Cross-App Background Secret",
                token: CorpusContent.backgroundToken,
                detail: "This separate application must never enter captured memory.",
                frame: NSRect(x: 520, y: 330, width: 760, height: 430),
                color: NSColor(calibratedRed: 0.98, green: 0.91, blue: 0.71, alpha: 1)
            )
            windows = [background]
            background.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            print("capture-overlap-background ready")
            print("background=\(CorpusContent.backgroundToken)")
            fflush(stdout)
            return
        }

        let background = makeWindow(
            title: "Background Secret",
            token: CorpusContent.backgroundToken,
            detail: "This token must never appear in captured memory.",
            frame: NSRect(x: 520, y: 330, width: 760, height: 430),
            color: NSColor(calibratedRed: 0.98, green: 0.91, blue: 0.71, alpha: 1)
        )
        let focused = makeWindow(
            title: "Focused Evidence",
            token: CorpusContent.focusedToken,
            detail: "This is the only token capture should retain.",
            frame: NSRect(x: 230, y: 170, width: 760, height: 430),
            color: NSColor(calibratedWhite: 0.98, alpha: 1)
        )
        let focusControl = makeWindow(
            title: "Focus Rebind Control",
            token: CorpusContent.focusControlToken,
            detail: "Deterministic focus-transition evidence.",
            frame: NSRect(x: 310, y: 230, width: 700, height: 390),
            color: NSColor(calibratedRed: 0.89, green: 0.94, blue: 0.98, alpha: 1)
        )
        windows = [background, focused, focusControl]
        background.orderFront(nil)
        focused.makeKeyAndOrderFront(nil)
        focusControl.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)

        if CommandLine.arguments.contains("--focus-churn") {
            startFocusChurn(focused: focused, control: focusControl)
        }

        print("capture-overlap-corpus ready")
        print("focused=\(CorpusContent.focusedToken)")
        print("background=\(CorpusContent.backgroundToken)")
        fflush(stdout)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        focusChurnTask?.cancel()
    }

    private func startFocusChurn(focused: NSWindow, control: NSWindow) {
        focusChurnTask = Task { @MainActor [weak focused, weak control] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(90))
                guard !Task.isCancelled, let focused, let control else { return }

                control.makeKeyAndOrderFront(nil)
                print("focus-churn=control")
                fflush(stdout)

                try? await Task.sleep(for: .milliseconds(1250))
                guard !Task.isCancelled else { return }
                control.orderOut(nil)
                focused.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                print("focus-churn=focused")
                fflush(stdout)
            }
        }
    }

    private func makeWindow(
        title: String,
        token: String,
        detail: String,
        frame: NSRect,
        color: NSColor
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.backgroundColor = color

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 52, left: 44, bottom: 44, right: 44)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 26, weight: .semibold)
        heading.textColor = .labelColor

        let tokenLabel = NSTextField(labelWithString: token)
        tokenLabel.font = .monospacedSystemFont(ofSize: 34, weight: .bold)
        tokenLabel.textColor = .labelColor
        tokenLabel.lineBreakMode = .byWordWrapping
        tokenLabel.maximumNumberOfLines = 2

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 18, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor

        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(tokenLabel)
        stack.addArrangedSubview(detailLabel)
        window.contentView = stack
        return window
    }
}

@main
private enum CaptureOverlapCorpusApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = CorpusAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        _ = delegate
    }
}
