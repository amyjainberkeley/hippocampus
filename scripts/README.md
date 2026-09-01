# scripts/

Build and packaging scripts for MCI / Hippocampus.

## build-installer.sh

Produces a distributable `Hippocampus-<version>.dmg` installer image. Supports two signing modes:

1. **Developer ID signed** — required for release because the file-Keychain ACL trusts stable executable identities.
2. **Development-only ad-hoc** — available only with `--debug --development-ad-hoc`; never a release artifact.

Stable Developer ID signing and notarization are both required for a release.
Missing credentials fail closed before the app is assembled.

### Prerequisites

- macOS (any recent version)
- Xcode Command Line Tools (`xcode-select --install`)
  - Provides: `hdiutil`, `codesign`, `SetFile`, `xcrun notarytool`
- Pre-built binaries:
  - `scripts/swift-package.sh build -c release --package-path apps/hippocampus`
  - `scripts/swift-package.sh build -c release --package-path adapters/macos/MCICaptureHelper`
  - `scripts/swift-package.sh build -c release --package-path apps/recall-ui`
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

# Disposable local debug artifact with unstable ad-hoc identity
./scripts/build-installer.sh --debug --development-ad-hoc

# Custom output directory
./scripts/build-installer.sh --dist /tmp/release
```

### Signing behavior

| Developer ID identity | `notarytool-profile` stored? | Result |
|---|---|---|
| Missing | — | Release fails closed |
| Yes | No | Release fails closed |
| Yes | Yes | App and outer DMG signed, notarized, stapled, and verified |

An ad-hoc artifact requires the explicit `--debug --development-ad-hoc` pair and is suitable only for disposable local development. Its unstable identity is not a Keychain ACL upgrade contract.

The script also accepts env vars `NOTARYTOOL_APPLE_ID`, `NOTARYTOOL_TEAM_ID`, `NOTARYTOOL_PASSWORD` as an alternative to the keychain profile (used in CI).

### Output

```
dist/Hippocampus-0.1.0.dmg         # Compressed DMG installer
dist/Hippocampus-0.1.0.dmg.sha256  # SHA-256 checksum sidecar
```

### Regenerating installer assets

The DMG background, EULA, and SLA resources are generated from source files. Committed versions are ready to use; regenerate only when sources change.

```bash
# Background (1280x800 Retina PNG from the canonical light brand system)
python3 assets/installer/generate-background.py

# EULA.rtf + sla.r (from docs/legal/terms-of-service.md)
python3 assets/installer/generate-eula.py

# Volume icon mirror (the build verifies it against the canonical icon)
cp assets/branding/AppIcon.icns assets/installer/volume-icon.icns

# Verify the installer cannot drift from the canonical app identity
./scripts/build-installer.sh --verify-assets
```

Both generators are pure Python stdlib (no Pillow, no external deps). The build script auto-regenerates missing assets.

| Asset | Source | Generator |
|---|---|---|
| `assets/installer/background.png` | `assets/branding/colors.json` + layered-memory mark | `generate-background.py` |
| `assets/installer/EULA.rtf` | `docs/legal/terms-of-service.md` | `generate-eula.py` |
| `assets/installer/sla.r` | `docs/legal/terms-of-service.md` | `generate-eula.py` |
| `assets/installer/volume-icon.icns` | `assets/branding/AppIcon.icns` | verified mirror; the build stages the canonical file directly |

### What the DMG contains

- `Hippocampus.app` — the application bundle
- `Applications` symlink — drag-target for installation
- `.background/background.png` — branded Finder background (hidden, 1280x800 Retina)
- `.VolumeIcon.icns` — volume icon (hidden)
- Software License Agreement — displayed on mount if SLA resources attached (requires Rez)

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
spctl --assess --type open --context context:primary-signature \
  --verbose dist/Hippocampus-0.1.0.dmg

# Verify notarization staple
stapler validate dist/Hippocampus-0.1.0.dmg
# Expected: "The validate action worked!"

# Inspect codesign details
codesign -dv --verbose=4 Hippocampus.app
```

### CI/CD release workflow

Tagged pushes (`v*`) trigger `.github/workflows/release.yml` which:
1. Freezes tag, bundle, changelog, feed, and model identity.
2. Reconstructs the hash-pinned model archive and builds every Swift/Rust binary.
3. Imports Developer ID, notarization, and matching Sparkle credentials.
4. Signs, notarizes, staples, and verifies the app and outer DMG.
5. Signs and verifies the staged appcast.
6. Uploads the DMG, checksum, and appcast to a draft GitHub release only.

The separate owner-triggered `.github/workflows/publish-release.yml` promotes
the inspected draft and then deploys its appcast through GitHub Pages.

Required GitHub secrets for signed releases:

| Secret | Description |
|---|---|
| `APPLE_CERTIFICATE_P12` | Base64-encoded `.p12` Developer ID Application certificate |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` file |
| `NOTARYTOOL_APPLE_ID` | Apple ID email for notarization |
| `NOTARYTOOL_TEAM_ID` | Apple Developer Team ID |
| `NOTARYTOOL_PASSWORD` | App-Specific Password for notarization |
| `SPARKLE_PRIVATE_KEY` | Sparkle private seed matching `SUPublicEDKey` |

Required repository variables:

| Variable | Description |
|---|---|
| `RELEASE_MODELS_URL` | Immutable HTTPS model-archive URL |
| `RELEASE_MODELS_SHA256` | Exact SHA-256 for that archive |

If any credential or model variable is absent, release packaging fails closed.

---

## demo.sh

Reproducible E2E pitch demo for Hippocampus / MCI. Automates the full demo pipeline: clean state, seed brain with synthetic data, build + launch app, run queries, exercise MCP server, capture screenshots, tear down.

### Prerequisites

- macOS with Xcode Command Line Tools
- Rust toolchain (`cargo`)
- Swift toolchain (invoked through `scripts/swift-package.sh`)
- `openssl` (ships with macOS)

### Subcommands

| Command | What it does |
|---|---|
| `clean` | Kill all MCI processes, delete demo brain + WAL/SHM files, archive logs to `/tmp` |
| `seed` | Generate ephemeral SQLCipher key at `/tmp/mci-demo-key.hex` (mode 0600), run `mci-seed-brain` to write 20 synthetic events |
| `boot` | Build Hippocampus.app via `build-app.sh`, requiring the stable Developer ID release identity, then launch |
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
