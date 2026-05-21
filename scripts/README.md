# scripts/

Build and packaging scripts for MCI / Hippocampus.

## build-installer.sh

Produces a distributable `Hippocampus-<version>.dmg` installer image. Supports three modes:

1. **Ad-hoc** (default when no cert present) — works for dev iteration, Gatekeeper warns on launch.
2. **Developer ID signed** — hardened runtime + timestamp, passes Gatekeeper.
3. **Developer ID signed + notarized** — Apple-verified, no warnings at all.

### Prerequisites

- macOS (any recent version)
- Xcode Command Line Tools (`xcode-select --install`)
  - Provides: `hdiutil`, `codesign`, `SetFile`, `xcrun notarytool`
- Pre-built binaries:
  - `swift build -c release` in `apps/hippocampus/`
  - `swift build -c release` in `adapters/macos/MCICaptureHelper/`
  - `cargo build --workspace --release`

### Apple Developer ID enrollment (one-time)

Developer ID codesigning + notarization requires an Apple Developer Program membership ($99/year).

1. Enroll at [developer.apple.com/programs/](https://developer.apple.com/programs/).
2. In Xcode → Settings → Accounts, sign in with your Apple ID.
3. Under your team, create a **Developer ID Application** certificate.
4. The certificate installs into your login keychain automatically.

### Notarization credentials setup (one-time)

Store credentials in the macOS keychain so `build-installer.sh` and CI can notarize:

```bash
xcrun notarytool store-credentials notarytool-profile \
    --apple-id "your@email.com" \
    --team-id "XXXXXXXXXX" \
    --password "xxxx-xxxx-xxxx-xxxx"  # App-Specific Password from appleid.apple.com
```

Generate an App-Specific Password at [appleid.apple.com](https://appleid.apple.com) → Security → App-Specific Passwords.

### Usage

```bash
# Full build (auto-detects Developer ID from keychain)
./scripts/build-installer.sh

# Explicit Developer ID override
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/build-installer.sh

# Skip build-app.sh (if .app is already assembled)
./scripts/build-installer.sh --skip-build

# Debug profile
./scripts/build-installer.sh --debug

# Custom output directory
./scripts/build-installer.sh --dist /tmp/release
```

### Signing behavior

| Keychain has Developer ID cert? | `notarytool-profile` stored? | Result |
|---|---|---|
| No | — | Ad-hoc sign (Gatekeeper warns) |
| Yes | No | Developer ID sign, skip notarization |
| Yes | Yes | Developer ID sign + notarize + staple |

The script also accepts env vars `NOTARYTOOL_APPLE_ID`, `NOTARYTOOL_TEAM_ID`, `NOTARYTOOL_PASSWORD` as an alternative to the keychain profile (used in CI).

### Output

```
dist/Hippocampus-0.1.0.dmg         # Compressed DMG installer
dist/Hippocampus-0.1.0.dmg.sha256  # SHA-256 checksum sidecar
```

### What the DMG contains

- `Hippocampus.app` — the application bundle
- `Applications` symlink — drag-target for installation
- `.background/background.png` — branded Finder background (hidden)
- `.VolumeIcon.icns` — volume icon (hidden)

### Installing from the DMG

1. Double-click `Hippocampus-<version>.dmg`
2. Drag `Hippocampus` to the `Applications` folder
3. Eject the disk image
4. Launch Hippocampus from Applications (or Spotlight)

### Gatekeeper warning (unsigned builds)

When the DMG is ad-hoc signed (no Developer ID), macOS Gatekeeper will show:

> "Hippocampus" can't be opened because it is from an unidentified developer.

**Workaround:** Right-click (or Control-click) the app in Applications, select "Open", then click "Open" in the dialog. This only needs to be done once.

With a Developer ID + notarization, no warning appears.

### Verification

```bash
# Verify DMG integrity
shasum -a 256 -c dist/Hippocampus-0.1.0.dmg.sha256

# Verify Gatekeeper acceptance (Developer ID builds)
spctl --assess --verbose Hippocampus.app
# Expected: "Hippocampus.app: accepted"

# Verify notarization staple
stapler validate dist/Hippocampus-0.1.0.dmg
# Expected: "The validate action worked!"

# Inspect codesign details
codesign -dv --verbose=4 Hippocampus.app
```

### CI/CD release workflow

Tagged pushes (`v*`) trigger `.github/workflows/release.yml` which:
1. Builds all binaries (Swift + Rust)
2. Imports Developer ID cert from `APPLE_CERTIFICATE_P12` secret
3. Stores notarytool credentials from `NOTARYTOOL_*` secrets
4. Runs `build-installer.sh` (auto-detects identity)
5. Uploads DMG + SHA-256 as draft GitHub Release artifacts

Required GitHub secrets for signed releases:

| Secret | Description |
|---|---|
| `APPLE_CERTIFICATE_P12` | Base64-encoded `.p12` Developer ID Application certificate |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` file |
| `NOTARYTOOL_APPLE_ID` | Apple ID email for notarization |
| `NOTARYTOOL_TEAM_ID` | Apple Developer Team ID |
| `NOTARYTOOL_PASSWORD` | App-Specific Password for notarization |

If secrets are absent, the workflow still runs but produces an ad-hoc signed DMG.

---

## demo.sh

Reproducible E2E pitch demo for Hippocampus / MCI. Automates the full demo pipeline: clean state, seed brain with synthetic data, build + launch app, run queries, exercise MCP server, capture screenshots, tear down.

### Prerequisites

- macOS with Xcode Command Line Tools
- Rust toolchain (`cargo`)
- Swift toolchain (`swift build`)
- `openssl` (ships with macOS)

### Subcommands

| Command | What it does |
|---|---|
| `clean` | Kill all MCI processes, delete demo brain + WAL/SHM files, archive logs to `/tmp` |
| `seed` | Generate ephemeral SQLCipher key at `/tmp/mci-demo-key.hex` (mode 0600), run `mci-seed-brain` to write 20 synthetic events |
| `boot` | Build Hippocampus.app via `build-app.sh`, embed Sparkle.framework, add `@executable_path/../Frameworks` rpath, ad-hoc codesign, launch |
| `query` | Run `mci-brain` CLI: stats, recent, search "snowflake", search "Cure53", search "zero-knowledge", show event 1 |
| `mcp-demo` | Send JSON-RPC 2.0 requests (initialize, tools/list, mci_recall, mci_stats) to `mci-agent mcp-serve` via stdin pipe |
| `screenshot` | Interactive `screencapture -w` for Hippocampus menu-bar and Recall UI windows; saves to `dist/demo-screenshots/` |
| `teardown` | Kill processes, archive demo brain to `/tmp`, delete key file |
| `full` | Run all subcommands in sequence: clean → seed → boot → query → mcp-demo → screenshot → teardown |

### Usage

```bash
# Full end-to-end demo
./scripts/demo.sh full

# Individual steps (e.g. iterate on query output)
./scripts/demo.sh clean
./scripts/demo.sh seed
./scripts/demo.sh query

# Just the MCP demo (after seed)
./scripts/demo.sh mcp-demo
```

### Security posture

- **Ephemeral key**: generated per-demo at `/tmp/mci-demo-key.hex`, mode 0600. Never exported to shell history.
- **Synthetic data only**: all seed events use `app_bundle_id = com.mci.demo.seed.*`. No real user content.
- **Teardown deletes**: demo brain archived to `/tmp` then removed from `~/Library/Application Support/MCI/`.
- **No network**: entire demo runs locally. No external calls.
