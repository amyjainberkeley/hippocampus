import AppKit

// Compile with -D SCREEN_PROOF_TESTING plus ScreenProofWindow.swift and
// ScreenProofExposure.swift and ScreenProofReceipt.swift. No application run
// loop, window or random phrase.
@main
@MainActor
struct ScreenProofTextViewTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let view = ScreenProofTextView(frame: NSRect(x: 0, y: 0, width: 732, height: 190))
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = false
        view.string = "SYNTHETIC TEST CONTENT"

        check(view.acceptsFirstResponder, "Committed text must retain native focus eligibility")
        check(view.accessibilityRole() == .textArea, "Committed text must retain its native AX role")

        view.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        check(view.string == "SYNTHETIC TEST CONTENT", "Typing must not invalidate the phrase commitment")

        view.insertText("X", replacementRange: NSRange(location: 0, length: view.string.utf16.count))
        check(view.string == "SYNTHETIC TEST CONTENT", "Replacement must not invalidate the phrase commitment")

        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        view.deleteBackward(nil)
        check(view.string == "SYNTHETIC TEST CONTENT", "Deletion must not invalidate the phrase commitment")

        check(view.accessibilityValue() == "SYNTHETIC TEST CONTENT", "Native AX must expose the unchanged text")
        check(view.window == nil, "Regression must not open a fixture window")
        print("PASS: screen-proof text preserves its commitment and native focus/AX behavior")
    }
}
