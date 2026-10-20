// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The menu-bar app's words for Demo Memory (SPEC-DELTA 6): Use Demo Memory,
/// Leave Demo Memory and the menu's Demo tag. Every string passes
/// `MenuBarCopyStyleTests`' rules and `scripts/check-launch-copy.sh`.
public enum DemoCopy {
    // MARK: The hi menu

    /// Shown while Option is held as the hi menu opens.
    public static let use = "Use Demo Memory…"
    /// While the made-up week is made and the window opens on it.
    public static let making = "Making Demo Memory…"
    /// The way back to the person's own memory, in the menu and Preferences.
    public static let leave = "Leave Demo Memory"
    /// While the window goes back to the person's own memory.
    public static let leaving = "Leaving Demo Memory…"
    /// The small tag in the menu, as by the window's title.
    public static let tag = "Demo"

    // MARK: The question before it starts

    public static let confirmTitle = "Use Demo Memory?"
    public static let confirmMessage =
        "Hippocampus opens a made-up week, for videos and screenshots. Remembering is paused until you leave it. Your own memory stays as it is."
    public static let confirmButton = "Use Demo Memory"
    public static let cancel = "Cancel"

    // MARK: Preferences › About

    public static let preferencesTitle = "Demo Memory"
    public static let preferencesOff = "A made-up week, for videos and screenshots. Your own memory stays as it is."
    public static let preferencesMaking = "Making the made-up week. The window opens on it in a moment."
    public static let preferencesOn = "In use. Remembering is paused until you leave."
    public static let preferencesLeaving = "Going back to your own memory."

    // MARK: When it can't

    public static let couldntUseTitle = "Couldn’t use Demo Memory"
    /// The week couldn't be made.
    public static let couldntMake = "The made-up week couldn’t be made. Your own memory is as it was. Try again."
    /// Part of the app that makes the week is not in this copy of Hippocampus.
    public static let missing = "Part of Hippocampus is missing. Reinstall it, then try again."
    /// Remembering didn't pause, so nothing changed.
    public static let couldntPause = "Remembering didn’t pause, so Demo Memory didn’t start. Your own memory is as it was."

    /// Every string above, for the copy tests.
    public static let all: [String] = [
        use, making, leave, leaving, tag,
        confirmTitle, confirmMessage, confirmButton, cancel,
        preferencesTitle, preferencesOff, preferencesMaking, preferencesOn, preferencesLeaving,
        couldntUseTitle, couldntMake, missing, couldntPause,
    ]
}
