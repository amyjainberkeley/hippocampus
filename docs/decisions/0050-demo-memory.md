# ADR-0050: Demo Memory, a made-up week for videos and screenshots

- Status: Accepted (2026-10-19). Numbered when the round merged (the records of 2026-10-19 are 0044 to 0050).
- Ratifier: Amy, October 19, SPEC-DELTA 6: "Amy is preparing a demo alongside the production app."

## Context

A launch video and the website need the real app running on a believable week, with screenshots, Working On, Resume, a calendar and an AI tool. Filming a real person's memory would show their own screens, people and calendar. Mock-ups drawn outside the app would show something the app doesn't do.

## Decision

1. **A made-up week, made by code in this repo, the same every time.** `mci-seed-brain --demo-week` writes the week of a made-up founder at a made-up company (Pebblewick), with made-up people and investors, its sessions, captions, readings, searches, About You lines and a made-up calendar (`demo-calendar.json`). `demo-screens` draws each screenshot and seals it with the capture helper's codec, so the window opens it exactly as it opens a person's own. Every date is relative to now, so the week always looks current. Stripe, Google Docs and Sheets, Slack, Zoom, Figma, Notion, Claude, VS Code and Terminal appear only as the apps and sites in use; no real person's name appears, and a test holds the people's names to that.
2. **A separate store in a separate folder,** with its own key in a file (a development file key, passed only to the processes reading Demo Memory), never the Keychain. The seeder refuses the person's own memory folder and any memory that isn't empty.
3. **Switching.** Option-click the hi in the menu bar for Use Demo Memory…, or open Preferences, under About. While it is in use, remembering is paused, the window and the agent read the made-up week, the window shows a Demo tag by its controls, and its footer says Demo Memory with one action, Leave Demo Memory, instead of a pause banner on every page. Leaving goes back to the person's own memory, untouched. A week left behind by a crash is cleared, and its pause undone, the next time the app opens.
4. **Hidden from ordinary use.** No sidebar row, no clutter; the menu item shows only with Option held.
5. **The same week drives the pictures.** The renderer makes the week with the same tools into a temporary folder and draws the real window on it (`--render-only=demo-`).

## Consequences

- AI tools the person connected keep reading their own memory while Demo Memory is in use: their settings name the real store. Disconnect them before filming a tool.
- Resume and Open Link open the week's addresses in the person's own browser, where their accounts are signed in; use a clean browser profile when filming those steps.
- Today shows Now for about five minutes after Use Demo Memory (the agent's session gap), then Where you left off.
- The release app bundles the seeder and `demo-screens` beside the agent; without them, Use Demo Memory… says a part is missing.
- Tests: the seeder's `demo_week` tests (deterministic output, made-up names, refusals), the `swift-test-demo-memory` lane, `DemoMemorySwitchingTests` and `DemoMemoryTests` in the app, `DemoCalendarTests` and `StatusBannerTests` in the window.
