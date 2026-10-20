// SPDX-License-Identifier: Apache-2.0
//
// ClipboardHygiene.swift — every copy for an AI tool (SPEC 5.3.6): kept on
// this Mac (not Universal Clipboard), marked so clipboard-history apps don't
// keep it, and cleared after 2 minutes if the clipboard still holds it. The
// window has its own copy of this code; both are tested.

import AppKit
import Foundation

/// The clipboard as a copy for an AI tool uses it. `NSPasteboard` is one;
/// tests use a fake that records what was asked.
@MainActor
public protocol HandoffPasteboard: AnyObject {
    var changeCount: Int { get }
    @discardableResult func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
    @discardableResult func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    @discardableResult func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool
    @discardableResult func clearContents() -> Int
}

extension NSPasteboard: HandoffPasteboard {}

@MainActor
public enum ClipboardHygiene {
    /// Tells clipboard-history apps not to keep or show it
    /// (nspasteboard.org).
    public static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// Tells them it is short-lived.
    public static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// How long a copy stays before it is cleared.
    public static let clearAfter: Duration = .seconds(120)

    /// Puts `text` on the clipboard for an AI tool, and clears it after two
    /// minutes if it is still there. False when it couldn't be written.
    @discardableResult
    public static func copy(
        _ text: String,
        to board: HandoffPasteboard = NSPasteboard.general,
        clearAfter delay: Duration = clearAfter,
        schedule: @escaping @MainActor (Duration, @escaping @MainActor () -> Void) -> Void = ClipboardHygiene.later
    ) -> Bool {
        write(to: board, delay: delay, schedule: schedule) { board in
            board.setString(text, forType: .string)
        }
    }

    /// A screenshot (JPEG) for an AI tool, the same way.
    @discardableResult
    public static func copy(
        jpeg: Data,
        to board: HandoffPasteboard = NSPasteboard.general,
        clearAfter delay: Duration = clearAfter,
        schedule: @escaping @MainActor (Duration, @escaping @MainActor () -> Void) -> Void = ClipboardHygiene.later
    ) -> Bool {
        write(to: board, delay: delay, schedule: schedule) { board in
            board.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))
        }
    }

    private static func write(
        to board: HandoffPasteboard,
        delay: Duration,
        schedule: @escaping @MainActor (Duration, @escaping @MainActor () -> Void) -> Void,
        content: (HandoffPasteboard) -> Bool
    ) -> Bool {
        // This Mac only: never Universal Clipboard.
        board.prepareForNewContents(with: .currentHostOnly)
        guard content(board) else { return false }
        board.setData(Data(), forType: concealed)
        board.setData(Data(), forType: transient)
        let written = board.changeCount
        schedule(delay) { [weak board] in
            // Only if nothing has been copied since.
            guard let board, board.changeCount == written else { return }
            board.clearContents()
        }
        return true
    }

    /// The real clock: runs `work` on the main actor after `delay`.
    public static func later(_ delay: Duration, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            work()
        }
    }
}
