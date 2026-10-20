// SPDX-License-Identifier: Apache-2.0
//
// FnKeyMonitor.swift — the Fn (Globe) key as Ask's key (SPEC-DELTA 7).

import Foundation

/// Fn (Globe), offered beside Shift twice as the key that opens Ask
/// (SPEC-DELTA 7). Shift twice stays the default: it works on every
/// keyboard and doesn't fight Wispr Flow or macOS dictation, which hold Fn.
///
/// Fn opens Ask only on a tap with no other key, so Fn with the arrows or
/// the F-keys keeps working. Before Fn can be chosen, the picker says so
/// when a known Fn app is installed, or when macOS's own setting for the
/// Globe key isn't Do Nothing, and it never takes Fn from another app
/// silently. A keyboard without Fn falls back to Shift twice. Like
/// `SoloKeyDetector`, it watches modifier keys only: it never reads or
/// stores a typed character.
///
/// A seam for now: Fn is never offered. The tap detector and the checks
/// before it is chosen land with the key picker in setup and Preferences.
public enum FnKeyMonitor {
    /// The device-independent modifier bit for Fn
    /// (`NSEvent.ModifierFlags.function`).
    public static let functionMask: UInt = 1 << 23

    /// Whether Fn can be offered as Ask's key on this Mac. Not yet.
    public static var isOffered: Bool { false }
}
