# ADR-0044: The window's places, and controls only the app can act on

- Status: Accepted (2026-10-19). Numbered when the round merged (the records of 2026-10-19 are 0044 to 0050).
- Replaces: RULINGS G5, "three places".
- Ratifier: Amy, after clicking through the prototype on October 19: "absolutely everything is perfect, thank you, start building." Her choice of the sidebar mix is in the build's SPEC-DELTA 1.

## Context

The window had three places, Overview, Ask and You. A person's own work had no place of its own, History lived under Ask's field, and the trust pages sat beside the memory pages. Two things in the old window were unsafe:

- **Anything could change remembering.** Pause and Resume reached the app over `DistributedNotificationCenter`, which any process on the Mac can post to. `PreferencesOpenRequest.swift` already said that channel "is not an authorization boundary".
- **Forgetting failed while remembering.** The agent holds the memory's only writer lease while it remembers, so a delete from the window failed, and the old advice was to quit first.

## Decision

1. **A few fixed places, two levels at most, nothing empty, nothing guessed.** The sidebar holds Today; Working On (the person's projects and documents, ADR-0045); Library, with History first and then Web Pages, Documents, Code, Conversations and Looked Up, each a lens over History that shows History's own rows filtered by kind; and, pinned at the bottom, About You, AI Tools and Privacy, with the status line and the gear. A kind's row appears once its page finds something, and stays. Keys never move: ⌘1 Today to ⌘9 AI Tools; a row not shown yet keeps its key. Privacy opens from its row and the status menu. The field ("Ask or search your memory") sits over every memory page, with Back and Forward.
2. **A private pipe.** The app starts the window with two anonymous pipes on file descriptors 3 and 4 (`posix_spawn` file actions, `MCI_WINDOW_CHANNEL=3,4`); the window marks them close-on-exec before anything else, so no child inherits them. Messages are versioned JSON lines of at most 4 KB. Pause, Resume, Turn On, Try Again, Open System Settings, and the forget hold travel only here. The app applies a request only where the same click in the menu bar would be allowed, and pushes the menu bar's own status row back, so the window, the menu bar, Ask's footer and Preferences say one thing. A window opened by hand has no pipe and no controls.
3. **The hold.** A forget while remembering asks the app for a hold: remembering stops the way Pause stops it, without touching the person's own pause, the window deletes, and the app starts again only if it was on. The window writes what it promised (moment ids and times, never content, mode 0600) before deleting, and a window that ended mid-forget finishes it on its next open. A few picked moments wait out an Undo note; anything larger asks first, with Cancel the default.
4. **Hides are ids.** What the person hides from the sidebar, or shows when a name looks personal, is kept by the agent's keyed item id (ADR-0045), never by name.

## Consequences

- No distributed notification can pause, resume or turn on remembering; a test posts one and nothing changes.
- The window follows the Mac's light or dark appearance, with contrast tests on its colours.
- Old links and route names (`overview`, `ask`, `you`) still land, on Today, History and About You.
- Tests: `SidebarModelTests`, `SidebarHidesTests`, `StatusBannerTests`, `WindowChannelTests`, `WindowChannelServerTests`, `CaptureHoldTests`, `ForgetCoordinatorTests`, `UserPauseControllerTests`, `StatusMenuModelTests`, `WindowContrastTests`, `RecallPlaceRoutingTests`.
