# Privacy

Hippocampus runs on your Mac and nowhere else. This page says what that means in practice, and links the code that enforces it, so you can check rather than trust.

## What is stored

- Text recognised from your screen, with the app, window title and URL it came from, and the time.
- Episodes (moments grouped by time and topic) and embedding vectors derived from that text.
- All of it in one SQLCipher-encrypted SQLite file under `~/Library/Application Support/MCI/`. The key is wrapped by a Keychain item gated on the Secure Enclave and cannot be exported.

## What leaves the machine

Nothing you captured. There is no server, no account and no sync service in this build, and there is no telemetry or crash reporting ([ADR-0025](docs/decisions/0025-analytics-telemetry-policy.md)).

Three network requests exist, and none carries memory content:

- `mci-agent mcp-sync` reads from MCP servers you register yourself, and refuses any address that is not loopback.
- The app's updater checks a release feed for a newer version.
- A build that ships without the bundled models downloads them from a public model host. The request carries nothing about you.

## What is refused before it is stored

- Password prompts, private-browsing windows and DRM-protected video are blocked before a frame is encoded.
- Extracted text is checked for one-time codes, bank alerts and API keys and refused. The fixtures for that check are in [`core/brain/fixtures/`](core/brain/fixtures/).

## Deleting

Deleting a memory crypto-shreds it. Deleting the database file and its key makes the data unrecoverable, and there is no copy anywhere else.

## Where this is decided

- [ADR-0001: privacy posture](docs/decisions/0001-privacy-posture-local-first-e2e.md)
- [ADR-0013: sensitive-surface suppression](docs/decisions/0013-native-grade-sensitive-surface-suppression.md)
- [SECURITY.md](SECURITY.md) for reporting a gap.
