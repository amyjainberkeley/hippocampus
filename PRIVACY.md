# Privacy

Hippocampus runs on your Mac and nowhere else. This page says what that means in practice, and links the code that enforces it, so you can check rather than trust.

## What is stored

- Text recognised from your screen, with the app, window title and URL it came from, and the time. The window you are working in is read when it changes; the other visible windows, on every display, are read every few seconds when their text changes and each line is filed under the window it came from ([ADR-0040](docs/decisions/0040-whole-screen-background-capture.md)). No screenshot is kept for those other windows.
- Episodes (moments grouped by time and topic) and embedding vectors derived from that text.
- Input counts per few seconds: how many keys, clicks, scrolls and pointer moves (never which keys), only for moments the privacy checks allowed.
- What Hippocampus understands: session notes, statements about how you work (with the moments they rest on), day accounts, and searches read from page addresses. They are written on your Mac by Apple's on-device model and deleted with any moment they rest on.
- All of it in one SQLCipher-encrypted SQLite file under `~/Library/Application Support/MCI/`. The key never lives inside the database: the app keeps it in your login Keychain, not synced, and AI clients you connect are given a Keychain reference, never the key. A development build can use a file key (`dev.key`, mode 0600) only when `MCI_DEVELOPMENT_FILE_KEY=1` is set. Wrapping it with the Secure Enclave is designed ([ADR-0008](docs/decisions/0008-encrypted-store-sqlcipher-sqlite-vec-keychain.md)) but not built yet.

## What leaves the machine

Nothing you captured. There is no server, no account and no sync service in this build, and there is no telemetry ([ADR-0025](docs/decisions/0025-analytics-telemetry-policy.md)). Crash reports stay off unless you set both `MCI_CRASH_REPORT_URL` and `MCI_CRASH_REPORT_OPTED_IN=1`.

Three network requests exist, and none carries memory content:

- `mci-agent mcp-sync` reads from MCP servers you register yourself, and refuses any address that is not loopback.
- The app's updater (Sparkle) checks `amyjainberkeley.github.io/hippocampus/appcast.xml` for a newer version and verifies its signature before installing.
- A build that ships without the bundled models downloads them from a public model host. The request carries nothing about you.

## What is refused before it is stored

- Password prompts, private-browsing windows and DRM-protected video are blocked before a frame is encoded.
- Password managers, Keychain Access, System Settings, browsers, notification banners, the Dock, Hippocampus itself and any app you exclude are removed from the whole-screen reads before any pixels exist.
- Extracted text is checked for one-time codes, bank alerts and API keys and refused. The fixtures for that check are in [`core/brain/fixtures/`](core/brain/fixtures/).

## Deleting

Deleting a memory removes it along with its vectors, entities and links, then rewrites the file (`VACUUM`) so the old pages are gone. Deleting the database file and its key makes the data unrecoverable, and there is no copy anywhere else.

## Where this is decided

- [ADR-0001: privacy posture](docs/decisions/0001-privacy-posture-local-first-e2e.md)
- [ADR-0013: sensitive-surface suppression](docs/decisions/0013-native-grade-sensitive-surface-suppression.md)
- [SECURITY.md](SECURITY.md) for reporting a gap.
