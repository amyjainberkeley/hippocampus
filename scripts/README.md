# scripts/

Build and packaging scripts for MCI / Hippocampus.

## build-installer.sh

Produces a distributable `Hippocampus-<version>.dmg` installer image.

### Prerequisites

- macOS (any recent version)
- Xcode Command Line Tools (`xcode-select --install`)
  - Provides: `hdiutil`, `codesign`, `SetFile`
- Pre-built binaries:
  - `swift build -c release` in `apps/hippocampus/`
  - `swift build -c release` in `adapters/macos/MCICaptureHelper/`
  - `cargo build --workspace --release`

### Usage

```bash
# Full build: compiles binaries + assembles .app + produces DMG
./scripts/build-installer.sh

# Skip build-app.sh (if .app is already assembled)
./scripts/build-installer.sh --skip-build

# Debug profile
./scripts/build-installer.sh --debug

# Custom output directory
./scripts/build-installer.sh --dist /tmp/release
```

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

This DMG is **ad-hoc signed** (not notarized with an Apple Developer ID). On first launch, macOS Gatekeeper will show:

> "Hippocampus" can't be opened because it is from an unidentified developer.

**Workaround:** Right-click (or Control-click) the app in Applications, select "Open", then click "Open" in the dialog. This only needs to be done once.

### Notarization (future)

When an Apple Developer ID is provisioned, the build pipeline will add:

```bash
# Codesign with Developer ID
codesign --force --options runtime \
    --sign "Developer ID Application: <TEAM>" \
    --timestamp \
    dist/Hippocampus.app

# Submit for notarization
xcrun notarytool submit dist/Hippocampus-0.1.0.dmg \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --wait

# Staple the notarization ticket
xcrun stapler staple dist/Hippocampus-0.1.0.dmg
```

This is tracked as Phase 5 follow-on work. See `docs/business/2026-05-20-gtm-positioning.md` for the signing key custody policy.

### Verification

```bash
# Verify DMG integrity
shasum -a 256 -c dist/Hippocampus-0.1.0.dmg.sha256

# Mount and inspect contents
hdiutil attach dist/Hippocampus-0.1.0.dmg
ls /Volumes/Hippocampus/
hdiutil detach /Volumes/Hippocampus
```
