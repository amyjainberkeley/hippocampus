# Privacy

Hippocampus runs on your Mac and nowhere else. This page says what that means in practice, and links the code that enforces it, so you can check rather than trust.

## What is stored

- Text recognised from your screen, with the app, window title and URL it came from, and the time.
- Episodes (moments grouped by time and topic) and embedding vectors derived from that text.
- All of it in one SQLCipher-encrypted SQLite file under `~/Library/Application Support/MCI/`. The key never lives inside the database. The command-line tools keep it in a file only your user can read (`dev.key`, mode 0600); the app on the v1 branch keeps it in the macOS Keychain, not synced. Wrapping it with the Secure Enclave is designed ([ADR-0008](docs/decisions/0008-encrypted-store-sqlcipher-sqlite-vec-keychain.md)) but not built yet.

## What leaves the machine

Nothing you captured. There is no server, no account and no sync service in this build, and there is no telemetry ([ADR-0025](docs/decisions/0025-analytics-telemetry-policy.md)). Crash reports stay off unless you set both `MCI_CRASH_REPORT_URL` and `MCI_CRASH_REPORT_OPTED_IN=1`.

Three network requests exist, and none carries memory content:

- `mci-agent mcp-sync` reads from MCP servers you register yourself, and refuses any address that is not loopback.
- The app's updater checks a release feed for a newer version.
- A build that ships without the bundled models downloads them from a public model host. The request carries nothing about you.

## What is refused before it is stored

- Password prompts, private-browsing windows and DRM-protected video are blocked before a frame is encoded.
- Extracted text is checked for one-time codes, bank alerts and API keys and refused. The fixtures for that check are in [`core/brain/fixtures/`](core/brain/fixtures/).

## Deleting

Deleting a memory removes it along with its vectors, entities and links, then rewrites the file (`VACUUM`) so the old pages are gone. Deleting the database file and its key makes the data unrecoverable, and there is no copy anywhere else.

## Where this is decided

- [ADR-0001: privacy posture](docs/decisions/0001-privacy-posture-local-first-e2e.md)
- [ADR-0013: sensitive-surface suppression](docs/decisions/0013-native-grade-sensitive-surface-suppression.md)
- [SECURITY.md](SECURITY.md) for reporting a gap.
