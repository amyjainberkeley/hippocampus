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
