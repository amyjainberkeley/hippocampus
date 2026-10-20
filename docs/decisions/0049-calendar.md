# ADR-0049: The calendar, optional and on this Mac

- Status: Accepted (2026-10-19). Numbered when the round merged (the records of 2026-10-19 are 0044 to 0050).
- Related: [ADR-0037](0037-deep-hook-plugins-calendar-notes-reminders-scaffold.md), a proposed calendar plugin that was never built. This record is what ships.
- Ratifier: Amy, October 19, SPEC-DELTA 5: "It syncs with your calendar."

## Context

A day reads better with its meetings in it: a call is easier to find as "Team sync" than as a Zoom window, and "when did I last meet with …?" is a question people ask. A calendar is also among the most private things on a Mac: who someone meets, and when. The capture helper had an older path that read the event happening now whenever macOS allowed it, whatever the person had chosen.

## Decision

1. **Off until the person turns it on,** in Preferences, under General, or with Show Calendar on Today, which is offered once. Turning it on asks macOS for full access to events (EventKit), once; nothing else ever asks. The choice is one defaults key, `ai.hippocampus.calendar.show`, which the app, the window and the capture helper share because they run in one bundle.
2. **Read on this Mac, and only these fields:** an event's title, start and end, whether it lasts all day, its calendar's name, and its place, where a link keeps only its site so meeting codes and passcodes are dropped. Attendees, the organizer, notes and links are never read; one file in each app is the only place an event is read, and a test holds it to that.
3. **What it is for:** thin labelled bars over Today's day strip; a call or meeting session named after its event; the meetings that overlapped an item's sessions, on its page; and Ask's answer to "When did I last meet with …?" from titles and times, with no memory sources.
4. **What it is never for:** it is not stored in the memory, About You never learns anything from it, and Hippocampus never sends it to an AI tool. The capture helper's note of the event happening now is read only while the calendar is on, and kept in memory only.
5. **Denied or taken back, nothing breaks.** Today drops the bars, Preferences says how to turn it back on, and a Mac that doesn't let apps read calendars never offers it.
6. **Demo Memory reads its own made-up calendar** and never asks macOS for the person's (ADR-0050). Tests and pictures use fixed stores and never ask the real system.

## Consequences

- Whether macOS lets the window's own process ask, rather than the app, is not yet checked on a signed build. If it can't, Today's Show Calendar says it couldn't ask, and Preferences' switch still works.
- Declined meetings still show as bars, since whether the person accepted lives in attendee data, which is never read.
- Reset Permissions… in Preferences doesn't reset Calendars.
- Tests: `CalendarPrivacyTests` and `CalendarCopyTests` in both apps, `SystemCalendarTests`, `EventKitCalendarStoreTests`, `CalendarReaderTests`, `DemoCalendarTests`, `TodayCalendarTests`, `CalendarQuestionTests`, `CalendarPreferenceModelTests`, the Ask panel's calendar tests, and the helper's `CalendarAttributionTests` (off means not read).
