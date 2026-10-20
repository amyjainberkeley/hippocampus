// SoloKeyTrigger.swift — the one key that opens Ask when tapped by itself.
//
// Carbon hotkeys (GlobalHotkeyManager) need a non-modifier key, so "tap
// right ⌘" or "tap Fn" cannot be one. This watches modifier changes instead.
// It never sees which keys are typed: a tap is "clean" when the system's own
// count of key presses and clicks did not move while the key was down.

import Foundation

/// Which key opens Ask when tapped alone. The raw values are stored in
/// `ai.hippocampus.prefs.askKey`, and onboarding and the window read them
/// (RULINGS X2), so they never change. Fn (Globe) joined them second, the
/// order Preferences offers them in (SPEC-DELTA 7).
public enum SoloKey: String, CaseIterable, Sendable, Identifiable {
    case shiftTwice
    /// Fn (Globe), tapped by itself, after its checks (`FnKeyMonitor`).
    case fn
    case rightShift
    case rightCommand
    case rightOption
    case off

    public var id: String { rawValue }

    /// The key's name in the Preferences picker.
    public var label: String {
        switch self {
        case .shiftTwice: "Shift twice"
        case .fn: "Fn (Globe)"
        case .rightShift: "Right Shift"
        case .rightCommand: "Right ⌘"
        case .rightOption: "Right ⌥"
        case .off: "Off"
        }
    }

    /// How the key is named where a shortcut is shown.
    public var shortcutLabel: String? {
        switch self {
        case .shiftTwice: "⇧⇧"
        case .fn: "fn"
        case .rightShift: "right ⇧"
        case .rightCommand: "right ⌘"
        case .rightOption: "right ⌥"
        case .off: nil
        }
    }

    /// The instruction for the key.
    public var phrase: String? {
        switch self {
        case .shiftTwice: "Press Shift twice"
        case .fn: "Tap Fn"
        case .rightShift: "Tap right Shift"
        case .rightCommand: "Tap right ⌘"
        case .rightOption: "Tap right ⌥"
        case .off: nil
        }
    }

    var keyCodes: Set<UInt16> {
        switch self {
        case .shiftTwice: [56, 60]
        case .fn: FnKeyMonitor.keyCodes
        case .rightShift: [60]
        case .rightCommand: [54]
        case .rightOption: [61]
        case .off: []
        }
    }

    /// Device-dependent modifier bits (IOKit NX_DEVICE…KEYMASK) for the key,
    /// and for Fn the device-independent function bit, which has no
    /// device-dependent one.
    var mask: UInt {
        switch self {
        case .shiftTwice: SoloKeyDetector.leftShift | SoloKeyDetector.rightShift
        case .fn: FnKeyMonitor.functionMask
        case .rightShift: SoloKeyDetector.rightShift
        case .rightCommand: SoloKeyDetector.rightCommand
        case .rightOption: SoloKeyDetector.rightOption
        case .off: 0
        }
    }

    var tapsNeeded: Int { self == .shiftTwice ? 2 : 1 }
}

/// Decides when the chosen modifier key was tapped by itself.
///
/// A tap is the key going down and coming back up within `longestTapMs`,
/// with no other modifier held and nothing else pressed or clicked in
/// between. A shortcut such as ⌘C is therefore never a tap, however fast.
public struct SoloKeyDetector: Sendable, Equatable {
    public static let longestTapMs: UInt64 = 350
    public static let doubleTapGapMs: UInt64 = 400

    static let leftControl: UInt = 0x0001
    static let leftShift: UInt = 0x0002
    static let rightShift: UInt = 0x0004
    static let leftCommand: UInt = 0x0008
    static let rightCommand: UInt = 0x0010
    static let leftOption: UInt = 0x0020
    static let rightOption: UInt = 0x0040
    static let rightControl: UInt = 0x2000
    static let everyModifier: UInt = 0x207F

    public let key: SoloKey
    private var downAtMs: UInt64?
    private var downActivity: UInt64 = 0
    private var firstTap: (atMs: UInt64, activity: UInt64)?

    public init(key: SoloKey) {
        self.key = key
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.downAtMs == rhs.downAtMs && lhs.downActivity == rhs.downActivity
            && lhs.firstTap?.atMs == rhs.firstTap?.atMs && lhs.firstTap?.activity == rhs.firstTap?.activity
    }

    /// The modifier bits that count for this key: the four modifiers
    /// either side, and Fn's own bit when Fn is the key. Caps Lock never
    /// counts.
    var watchedModifiers: UInt {
        key == .fn ? Self.everyModifier | FnKeyMonitor.functionMask : Self.everyModifier
    }

    /// Feed every modifier change. Returns true when Ask should open.
    ///
    /// - Parameters:
    ///   - keyCode: the modifier key that changed.
    ///   - flags: the device-dependent modifier bits now held.
    ///   - activity: a running count of key presses and clicks. Only whether
    ///     it moved matters.
    ///   - atMs: a monotonic time in milliseconds.
    public mutating func modifiersChanged(keyCode: UInt16, flags: UInt, activity: UInt64, atMs: UInt64) -> Bool {
        guard key != .off else { return false }
        let held = flags & watchedModifiers
        if held & ~key.mask != 0 {
            // Another modifier is involved: a shortcut, not a tap.
            downAtMs = nil
            firstTap = nil
            return false
        }
        if held & key.mask != 0 {
            if downAtMs == nil, key.keyCodes.contains(keyCode) {
                downAtMs = atMs
                downActivity = activity
            }
            return false
        }
        // Every modifier is up.
        guard let wentDown = downAtMs, key.keyCodes.contains(keyCode) else {
            downAtMs = nil
            return false
        }
        downAtMs = nil
        guard activity == downActivity, atMs >= wentDown, atMs - wentDown <= Self.longestTapMs else {
            firstTap = nil
            return false
        }
        guard key.tapsNeeded == 2 else { return true }
        if let first = firstTap, first.activity == activity, atMs - first.atMs <= Self.doubleTapGapMs {
            firstTap = nil
            return true
        }
        firstTap = (atMs, activity)
        return false
    }
}
