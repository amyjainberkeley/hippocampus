// SPDX-License-Identifier: Apache-2.0
//
// SetupClipboard.swift — setup's one way onto the clipboard: what a step asks
// the person to paste somewhere else on this Mac (an address for a browser's
// extensions page). It stays on this Mac (never Universal Clipboard) and is
// marked concealed and transient, so clipboard-history apps don't keep it.
// A test fails if any other file in setup writes to a pasteboard.

#if canImport(AppKit)
import AppKit

/// The clipboard as setup uses it. `NSPasteboard` is one; tests use a fake
/// that records what was asked.
@MainActor
public protocol SetupPasteboard: AnyObject {
    @discardableResult func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
    @discardableResult func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    @discardableResult func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: SetupPasteboard {}

@MainActor
public enum SetupClipboard {
    /// Tells clipboard-history apps not to keep or show it (nspasteboard.org).
    public static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// Tells them it is short-lived: it is pasted once, into the next step.
    public static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Puts `text` on the clipboard for the next step. False when it
    /// couldn't be written.
    @discardableResult
    public static func copy(_ text: String, to board: SetupPasteboard = NSPasteboard.general) -> Bool {
        // This Mac only: never Universal Clipboard.
        board.prepareForNewContents(with: .currentHostOnly)
        guard board.setString(text, forType: .string) else { return false }
        board.setData(Data(), forType: concealed)
        board.setData(Data(), forType: transient)
        return true
    }
}
#endif
