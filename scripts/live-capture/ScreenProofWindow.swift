import AppKit
import CryptoKit
import Security

// Standalone qualification fixture. It never opens the brain, reads keys,
// writes a document, or prints the phrase. Its only output is a hash receipt.
@MainActor
final class ScreenProofWindow: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var textView: NSTextView!
    private var generated = false
    private var exposure = ScreenProofExposure()
    private var exposureLabel: NSTextField!
    private var exposureTimer: Timer?
    private var phraseHash = ""
    private var lastExposureBucket = -1
    private var lastExposureEligible: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Hippocampus Screen Proof"
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

        textView = NSTextView(frame: NSRect(x: 24, y: 104, width: 732, height: 190))
        textView.font = .monospacedSystemFont(ofSize: 24, weight: .regular)
        textView.textColor = .black
        textView.backgroundColor = .white
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.string = "Generate a phrase when this window is visible."
        root.addSubview(textView)

        let button = NSButton(title: "Generate once", target: self, action: #selector(generate(_:)))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 28, y: 40, width: 150, height: 36)
        root.addSubview(button)
        exposureLabel = NSTextField(labelWithString: "")
        exposureLabel.font = .systemFont(ofSize: 13)
        exposureLabel.textColor = .darkGray
        exposureLabel.frame = NSRect(x: 205, y: 44, width: 535, height: 26)
        root.addSubview(exposureLabel)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        exposureTimer = Timer.scheduledTimer(
            timeInterval: 1, target: self, selector: #selector(sampleExposure),
            userInfo: nil, repeats: true
        )
    }

    @objc private func generate(_ sender: NSButton) {
        guard !generated, window.isKeyWindow, NSApp.isActive else { return }
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
        let receipt: [String: Any] = [
            "schema_version": 1,
            "record_type": "phrase_generated",
            "phrase_sha256": phraseHash,
            "generated_at_us": UInt64(Date().timeIntervalSince1970 * 1_000_000),
            "window_was_key": window.isKeyWindow,
            "app_was_active": NSApp.isActive,
        ]
        writeReceipt(receipt)
        sampleExposure()
    }

    @objc private func sampleExposure() {
        guard generated else { return }
        let visible = window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
        let textFocused = window.firstResponder === textView
        let eligible = NSApp.isActive && window.isKeyWindow && visible && textFocused
        exposure.sample(at: ProcessInfo.processInfo.systemUptime, eligible: eligible)
        let seconds = Int(min(20, exposure.seconds))
        exposureLabel.stringValue = "Foreground observed: \(seconds) / 20 seconds. Capture is checked separately."
        let bucket = seconds / 5
        guard bucket != lastExposureBucket || eligible != lastExposureEligible else { return }
        lastExposureBucket = bucket
        lastExposureEligible = eligible
        writeReceipt([
            "schema_version": 1,
            "record_type": "exposure_observation",
            "phrase_sha256": phraseHash,
            "observed_at_us": UInt64(Date().timeIntervalSince1970 * 1_000_000),
            "continuous_seconds": seconds,
            "app_was_active": NSApp.isActive,
            "window_was_key": window.isKeyWindow,
            "window_was_visible": visible,
            "text_was_focused": textFocused,
        ])
    }

    private func writeReceipt(_ receipt: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([10]))
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
