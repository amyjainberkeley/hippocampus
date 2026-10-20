// SPDX-License-Identifier: Apache-2.0
//
// ClipboardHygiene.swift — the window's one way onto the clipboard. Every
// copy stays on this Mac (never Universal Clipboard) and is marked concealed
// so clipboard-history apps don't keep it. A copy for an AI tool (SPEC 5.3.6)
// is also marked transient and cleared after 2 minutes if the clipboard
// still holds it; a copy the person makes to keep (Copy Text, a link, an
// answer, ⌘C in a reading) stays until something else is copied. Copies
// AppKit makes itself (⌘C on selected text, a view's Copy command) follow
// the same rules through `ruleEveryCopy()`, which the window turns on at
// launch. The menu-bar app has its own copy of this code; both are tested,
// and a test fails if any other file in either app writes to a pasteboard.

import AppKit
import Foundation
import ObjectiveC
import os

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
    /// Tells clipboard-history apps not to keep or show it (nspasteboard.org).
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

    /// Puts `text` on the clipboard for the person to paste where they like:
    /// on this Mac only, concealed from clipboard-history apps, and kept
    /// until something else is copied (not transient, never cleared). False
    /// when it couldn't be written.
    @discardableResult
    public static func copyToKeep(_ text: String, to board: HandoffPasteboard = NSPasteboard.general) -> Bool {
        // This Mac only: never Universal Clipboard.
        board.prepareForNewContents(with: .currentHostOnly)
        guard board.setString(text, forType: .string) else { return false }
        board.setData(Data(), forType: concealed)
        return true
    }

    /// The real clock: runs `work` on the main actor after `delay`.
    public static func later(_ delay: Duration, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            work()
        }
    }

    /// The types a reading's selection is written as for a drag or a
    /// Service: the text, and the concealed marker.
    public static let selectionTypes: [NSPasteboard.PasteboardType] = [.string, concealed]

    /// One of `selectionTypes`, as AppKit asks for it while it writes a
    /// selection for a drag or a Service (it has declared the types). ⌘C
    /// goes through `copyToKeep` instead.
    @discardableResult
    public static func writeSelection(
        _ text: String, to board: HandoffPasteboard, type: NSPasteboard.PasteboardType
    ) -> Bool {
        switch type {
        case .string: return board.setString(text, forType: .string)
        case concealed: return board.setData(Data(), forType: concealed)
        default: return false
        }
    }

    /// A screenshot as an AI tool takes it (SPEC 5.3.7): at most 1,568
    /// pixels on its long edge, as JPEG, with no metadata.
    public static func jpegForAI(_ image: Data, longEdge: Int = 1_568) -> Data? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        // Pixels only: no EXIF, GPS or any other metadata goes.
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// The copies AppKit and SwiftUI write themselves, by the same rules:
    /// ⌘C on selected text, a view's Copy command, Cut in a text field. Each
    /// one on the general clipboard stays on this Mac and is marked concealed,
    /// as `copyToKeep` does. Called once, at launch; calling it again changes
    /// nothing.
    public nonisolated static func ruleEveryCopy() {
        ClipboardGuard.cover(.general)
    }
}

// MARK: - The copies AppKit makes

/// NSPasteboard with the clipboard rules on the pasteboards it covers: a
/// method that starts new contents (`clearContents()`,
/// `declareTypes(_:owner:)`, `prepareForNewContents(with:)`) starts them on
/// this Mac only, and a method that writes (`writeObjects(_:)`, `setString`,
/// `setData`, `setPropertyList`) marks the first item concealed once it has
/// written. Other pasteboards (a drag, Find, Services) are left alone.
///
/// It works by exchanging those NSPasteboard methods for the ones below, once
/// per process. Inside one of them, AppKit's own nested calls and the marking
/// pass straight through, so nothing is done twice.
enum ClipboardGuard {
    private static let covered = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private static let installed = OSAllocatedUnfairLock(initialState: false)
    /// The options the last new contents of a covered pasteboard started
    /// with, as a raw value. Content-free; tests read it, as no AppKit call
    /// can.
    private static let lastStart = OSAllocatedUnfairLock<UInt?>(initialState: nil)
    private static let depthKey = "ai.hippocampus.window.clipboard-guard"

    static var concealed: NSPasteboard.PasteboardType { .init("org.nspasteboard.ConcealedType") }

    /// Applies the rules to the pasteboard called `name` from now on.
    static func cover(_ name: NSPasteboard.Name) {
        let raw = name.rawValue
        covered.withLock { _ = $0.insert(raw) }
        let first = installed.withLock { done in
            defer { done = true }
            return !done
        }
        guard first else { return }
        exchange(#selector(NSPasteboard.clearContents), #selector(NSPasteboard.windowGuardClearContents))
        exchange(#selector(NSPasteboard.prepareForNewContents(with:)),
                 #selector(NSPasteboard.windowGuardPrepareForNewContents(with:)))
        exchange(#selector(NSPasteboard.declareTypes(_:owner:)), #selector(NSPasteboard.windowGuardDeclareTypes(_:owner:)))
        exchange(#selector(NSPasteboard.writeObjects(_:)), #selector(NSPasteboard.windowGuardWriteObjects(_:)))
        exchange(#selector(NSPasteboard.setString(_:forType:)), #selector(NSPasteboard.windowGuardSetString(_:forType:)))
        exchange(#selector(NSPasteboard.setData(_:forType:)), #selector(NSPasteboard.windowGuardSetData(_:forType:)))
        exchange(#selector(NSPasteboard.setPropertyList(_:forType:)),
                 #selector(NSPasteboard.windowGuardSetPropertyList(_:forType:)))
    }

    private static func exchange(_ original: Selector, _ replacement: Selector) {
        guard let original = class_getInstanceMethod(NSPasteboard.self, original),
              let replacement = class_getInstanceMethod(NSPasteboard.self, replacement) else { return }
        method_exchangeImplementations(original, replacement)
    }

    /// Whether the rules cover the pasteboard called `name`.
    static func covers(_ name: NSPasteboard.Name) -> Bool {
        let raw = name.rawValue
        return covered.withLock { $0.contains(raw) }
    }

    /// Whether the rules apply to this call: a covered pasteboard, and not
    /// inside one of the guard's own methods on this thread.
    static func applies(to board: NSPasteboard) -> Bool {
        guard ((Thread.current.threadDictionary[depthKey] as? Int) ?? 0) == 0 else { return false }
        return covers(board.name)
    }

    /// Runs `body` with the rules passing straight through on this thread.
    static func passingThrough<T>(_ body: () -> T) -> T {
        let dictionary = Thread.current.threadDictionary
        let depth = (dictionary[depthKey] as? Int) ?? 0
        dictionary[depthKey] = depth + 1
        defer { dictionary[depthKey] = depth }
        return body()
    }

    static func started(_ options: NSPasteboard.ContentsOptions) {
        let raw = options.rawValue
        lastStart.withLock { $0 = raw }
    }

    /// The options the last new contents of a covered pasteboard started
    /// with, or nil when none has started since `forgetLastStart()`.
    static var lastStartOptions: NSPasteboard.ContentsOptions? {
        lastStart.withLock { $0 }.map(NSPasteboard.ContentsOptions.init(rawValue:))
    }

    static func forgetLastStart() {
        lastStart.withLock { $0 = nil }
    }

    /// Marks what was just written concealed, on the first item, once.
    static func markConcealed(_ board: NSPasteboard) {
        guard board.types?.contains(concealed) != true else { return }
        _ = board.setData(Data(), forType: concealed)
    }
}

extension NSPasteboard {
    // After `ClipboardGuard.cover`, each of these runs in place of the
    // AppKit method it names, and calling itself calls AppKit's.

    @objc fileprivate func windowGuardClearContents() -> Int {
        guard ClipboardGuard.applies(to: self) else { return windowGuardClearContents() }
        ClipboardGuard.started(.currentHostOnly)
        return ClipboardGuard.passingThrough { prepareForNewContents(with: .currentHostOnly) }
    }

    @objc fileprivate func windowGuardPrepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        guard ClipboardGuard.applies(to: self) else { return windowGuardPrepareForNewContents(with: options) }
        let options = options.union(.currentHostOnly)
        ClipboardGuard.started(options)
        return ClipboardGuard.passingThrough { windowGuardPrepareForNewContents(with: options) }
    }

    /// `declareTypes` empties the pasteboard and declares the types; this
    /// does the same, starting the new contents on this Mac only, and marks
    /// them concealed.
    @objc fileprivate func windowGuardDeclareTypes(_ newTypes: [NSPasteboard.PasteboardType], owner newOwner: Any?) -> Int {
        guard ClipboardGuard.applies(to: self) else { return windowGuardDeclareTypes(newTypes, owner: newOwner) }
        ClipboardGuard.started(.currentHostOnly)
        return ClipboardGuard.passingThrough {
            _ = prepareForNewContents(with: .currentHostOnly)
            let count = addTypes(newTypes, owner: newOwner)
            ClipboardGuard.markConcealed(self)
            return count
        }
    }

    @objc fileprivate func windowGuardWriteObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        guard ClipboardGuard.applies(to: self) else { return windowGuardWriteObjects(objects) }
        return ClipboardGuard.passingThrough {
            let wrote = windowGuardWriteObjects(objects)
            if wrote { ClipboardGuard.markConcealed(self) }
            return wrote
        }
    }

    @objc fileprivate func windowGuardSetString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        guard ClipboardGuard.applies(to: self) else { return windowGuardSetString(string, forType: dataType) }
        return ClipboardGuard.passingThrough {
            let wrote = windowGuardSetString(string, forType: dataType)
            if wrote { ClipboardGuard.markConcealed(self) }
            return wrote
        }
    }

    @objc fileprivate func windowGuardSetData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        guard ClipboardGuard.applies(to: self) else { return windowGuardSetData(data, forType: dataType) }
        return ClipboardGuard.passingThrough {
            let wrote = windowGuardSetData(data, forType: dataType)
            if wrote { ClipboardGuard.markConcealed(self) }
            return wrote
        }
    }

    @objc fileprivate func windowGuardSetPropertyList(_ plist: Any, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        guard ClipboardGuard.applies(to: self) else { return windowGuardSetPropertyList(plist, forType: dataType) }
        return ClipboardGuard.passingThrough {
            let wrote = windowGuardSetPropertyList(plist, forType: dataType)
            if wrote { ClipboardGuard.markConcealed(self) }
            return wrote
        }
    }
}
