import AppKit
import CryptoKit
import Security

@MainActor
final class ScreenProofTextView: NSTextView {
    // Retain native editable-text focus/AX behavior without letting input
    // alter the visible phrase after its hash has been committed.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        false
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        false
    }
}

@MainActor
final class ScreenProofControls {
    let textView = ScreenProofTextView(frame: NSRect(x: 24, y: 104, width: 732, height: 190))
    let generateButton = NSButton(title: "Generate once", target: nil, action: nil)
    let exposureLabel = NSTextField(labelWithString: "")

    init() {
        textView.setAccessibilityIdentifier("screen-proof.phrase")
        generateButton.setAccessibilityIdentifier("screen-proof.generate")
        exposureLabel.setAccessibilityIdentifier("screen-proof.exposure")
    }
}

// Standalone qualification fixture. It never opens the brain, reads keys,
// writes a document, or prints the phrase. Its only output is a hash receipt.
@MainActor
final class ScreenProofWindow: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let controls = ScreenProofControls()
    private var textView: NSTextView { controls.textView }
    private var generated = false
    private var exposure = ScreenProofExposure()
    private var exposureLabel: NSTextField { controls.exposureLabel }
    private var exposureTimer: Timer?
    private var phraseHash: String?
    private var observationBudget: ScreenProofObservationBudget!
    private var didEmitReady = false
    private var receiptSink: ScreenProofReceiptSink?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            receiptSink = try ScreenProofReceiptSink()
        } catch {
            FileHandle.standardError.write(Data("Proof receipt creation failed.\n".utf8))
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Hippocampus Screen Proof"
        window.setAccessibilityIdentifier("screen-proof.window")
        window.delegate = self
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentView!.bounds)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.white.cgColor
        window.contentView = root

        let heading = NSTextField(labelWithString: "Screen memory check")
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        heading.textColor = .black
        heading.frame = NSRect(x: 28, y: 318, width: 720, height: 32)
        root.addSubview(heading)

        textView.font = .monospacedSystemFont(ofSize: 24, weight: .regular)
        textView.textColor = .black
        textView.backgroundColor = .white
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.string = "Generate a phrase when this window is visible."
        root.addSubview(textView)

        let button = controls.generateButton
        button.target = self
        button.action = #selector(generate(_:))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 28, y: 40, width: 150, height: 36)
        root.addSubview(button)
        exposureLabel.font = .systemFont(ofSize: 13)
        exposureLabel.textColor = .darkGray
        exposureLabel.frame = NSRect(x: 205, y: 44, width: 535, height: 26)
        root.addSubview(exposureLabel)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        observationBudget = ScreenProofObservationBudget(startedAt: ProcessInfo.processInfo.systemUptime)
        sampleExposure()
        exposureTimer = Timer.scheduledTimer(
            timeInterval: 1, target: self, selector: #selector(sampleExposure),
            userInfo: nil, repeats: true
        )
    }

    @objc private func generate(_ sender: NSButton) {
        guard !generated, window.isKeyWindow, NSApp.isActive,
              observationBudget.permitsGeneration(at: ProcessInfo.processInfo.systemUptime),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        else { return }
        let vocabulary = [
            "amber", "birch", "cedar", "coral", "delta", "ember", "fern", "fjord",
            "garden", "harbor", "indigo", "jade", "kettle", "lantern", "maple", "meadow",
            "nectar", "olive", "orchard", "paper", "pebble", "quartz", "ribbon", "river",
            "silver", "timber", "tulip", "velvet", "violet", "willow", "winter", "yellow",
        ]
        var bytes = [UInt8](repeating: 0, count: 12)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            textView.string = "Random generation unavailable."
            return
        }
        let words = bytes.map { vocabulary[Int($0 & 31)] }
        let phrase = words.joined(separator: " ")
        let lines = stride(from: 0, to: words.count, by: 4).map {
            words[$0 ..< min($0 + 4, words.count)].joined(separator: " ")
        }
        textView.string = lines.joined(separator: "\n")
        textView.isEditable = true
        window.makeFirstResponder(textView)
        generated = true
        sender.isEnabled = false
        phraseHash = SHA256.hash(data: Data(phrase.utf8)).map { String(format: "%02x", $0) }.joined()
        let foreground = observeForeground()
        exposure.sample(at: ProcessInfo.processInfo.systemUptime, eligible: foreground.eligible)
        writeReceipt(kind: .phraseGenerated, foreground: foreground)
    }

    @objc private func sampleExposure() {
        switch observationBudget.next(at: ProcessInfo.processInfo.systemUptime) {
        case .wait: return
        case .finish:
            exposureTimer?.invalidate()
            exposure.sample(at: ProcessInfo.processInfo.systemUptime, eligible: false)
            controls.generateButton.isEnabled = false
            exposureLabel.stringValue = "Observation ended. Capture is checked separately."
            writeReceipt(kind: .observationFinished, foreground: nil)
            return
        case .sample: break
        }
        let foreground = observeForeground()
        exposure.sample(at: ProcessInfo.processInfo.systemUptime, eligible: generated && foreground.eligible)
        let seconds = Int(min(20, exposure.seconds))
        exposureLabel.stringValue = "Foreground observed: \(seconds) / 20 seconds. Capture is checked separately."
        let kind: ScreenProofReceipt.Kind = !didEmitReady ? .fixtureReady
            : (generated ? .exposureObservation : .foregroundObservation)
        didEmitReady = true
        writeReceipt(kind: kind, foreground: foreground)
    }

    private func observeForeground() -> ScreenProofForeground {
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        // Only numeric metadata is selected. Never read names, titles, AX text or pixels.
        let windows = raw?.compactMap { entry -> ScreenProofSystemWindow? in
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int,
                  let layer = entry[kCGWindowLayer as String] as? Int else { return nil }
            return ScreenProofSystemWindow(number: number, ownerPid: pid, layer: layer)
        }
        let after = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let visible = window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
        return ScreenProofForeground(
            fixturePid: Int(ProcessInfo.processInfo.processIdentifier), fixtureWindowNumber: window.windowNumber,
            systemPidBefore: before.map(Int.init), systemPidAfter: after.map(Int.init), windows: windows,
            appActive: NSApp.isActive, windowKey: window.isKeyWindow, windowVisible: visible,
            textFocused: window.firstResponder === textView
        )
    }

    private func writeReceipt(kind: ScreenProofReceipt.Kind, foreground: ScreenProofForeground?) {
        let receipt = ScreenProofReceipt(kind: kind,
                                        atUs: UInt64(Date().timeIntervalSince1970 * 1_000_000),
                                        phraseHash: phraseHash, foreground: foreground,
                                        seconds: Int(min(20, exposure.seconds)))
        if let line = try? receipt.encodedLine() {
            do {
                try receiptSink?.append(line)
            } catch {
                exposureTimer?.invalidate()
                controls.generateButton.isEnabled = false
                exposureLabel.stringValue = "Receipt unavailable. Restart the check."
                return
            }
            FileHandle.standardOutput.write(line)
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        exposure.sample(at: ProcessInfo.processInfo.systemUptime, eligible: false)
    }

    func windowDidResignKey(_ notification: Notification) {
        exposure.sample(at: ProcessInfo.processInfo.systemUptime, eligible: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        exposureTimer?.invalidate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

#if !SCREEN_PROOF_TESTING
@main
@MainActor
enum ScreenProofApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = ScreenProofWindow()
        app.delegate = delegate
        app.run()
    }
}
#endif
