import AppKit
import CryptoKit
import Security

// Standalone qualification fixture. It never opens the brain, reads keys,
// writes a document, or prints the phrase. Its only output is a hash receipt.
@MainActor
final class ScreenProofWindow: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var textView: NSTextView!
    private var generated = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Hippocampus Screen Proof"
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
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        let receipt: [String: Any] = [
            "schema_version": 1,
            "phrase_sha256": SHA256.hash(data: Data(phrase.utf8)).map { String(format: "%02x", $0) }.joined(),
            "generated_at_us": UInt64(Date().timeIntervalSince1970 * 1_000_000),
            "window_was_key": window.isKeyWindow,
            "app_was_active": NSApp.isActive,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = ScreenProofWindow()
app.delegate = delegate
app.run()
