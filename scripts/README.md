# scripts/

Build, release and test scripts for Hippocampus. `check.sh` runs every test
lane (`./scripts/check.sh --help` lists them).

## release-0.3.0.sh

Builds, signs, notarizes and checks a release on this Mac, from the release
branch, and uploads nothing. `docs/release/RELEASE_CHECKLIST.md` is the full
list.

```bash
scripts/release-0.3.0.sh --check     # every quick gate; builds and commits nothing
scripts/release-0.3.0.sh --dry-run   # builds and signs here; notarizes, commits and opens nothing
scripts/release-0.3.0.sh --notes docs/release/notes-0.3.0.md
```

In order, stopping at the first failure: a preflight (branch, clean tree,
release identity, CHANGELOG, models, OCR worker, toolchain, Developer ID,
notary profile, Sparkle key, power and disk); a fresh OCR worker if
`tools/ocr` changed; the `docs/STATUS.md` baseline stamp, committed; release
binaries, stripped, with their dSYMs kept; the signed app (`build-app.sh`);
the signed, notarized and stapled DMG (`build-installer.sh`); checks of the
DMG and the app inside it; and `appcast.xml`, signed with the Sparkle key
file and checked by the release identity gate. It prints the files to upload
and the `gh` commands for the draft release. A dry run's files are for
inspection only; never upload them.

## build-installer.sh

Produces a distributable `Hippocampus-<version>.dmg` installer image. Supports two signing modes:

1. **Developer ID signed** — required for release because the file-Keychain ACL trusts stable executable identities.
2. **Development-only ad-hoc** — available only with `--debug --development-ad-hoc`; never a release artifact.

Stable Developer ID signing and notarization are both required for a release.
Missing credentials fail closed before the app is assembled.

### Prerequisites

- Xcode 26, selected with `xcode-select` (it provides `hdiutil`, `codesign` and `xcrun notarytool`)
- A fresh OCR worker in `tools/ocr/dist` (`tools/ocr/README.md`)
- Pre-built binaries:
  - `scripts/swift-package.sh build -c release --package-path apps/hippocampus`
  - `scripts/swift-package.sh build -c release --package-path adapters/macos/MCICaptureHelper`
  - `scripts/swift-package.sh build -c release --package-path apps/recall-ui`
  - `scripts/swift-package.sh build -c release --package-path apps/onboarding`
  - `scripts/swift-package.sh build -c release --package-path apps/mind`
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
dist/Hippocampus-<version>.dmg         # The installer image, LZMA-compressed (ULMO)
dist/Hippocampus-<version>.dmg.sha256  # SHA-256 checksum sidecar
dist/Hippocampus.dmg               # The same bytes under a name that never changes
dist/Hippocampus.dmg.sha256        # Its checksum, under its own name
```

Upload both names to the release, so
`https://github.com/amyjainberkeley/hippocampus/releases/latest/download/Hippocampus.dmg`
always downloads the newest build. The volume is named `Hippocampus`; the
commit and source digest are in the app's `build-provenance.json`, never in
the window a downloader sees.

### Regenerating installer assets

The DMG background, the Legal folder's icon and the EULA are generated from
source files. Committed versions are ready to use; regenerate only when
sources change.

```bash
# Background: 1280x864 at 144 dpi, the window's 640x432 points. The words
# "Drag to Applications" over an arrow, a one-line update note, nothing else.
python3 assets/installer/generate-background.py

# EULA.rtf (from docs/legal/terms-of-service.md)
python3 assets/installer/generate-eula.py

# Volume icon mirror (the build verifies it against the canonical icon)
cp assets/branding/AppIcon.icns assets/installer/volume-icon.icns

# Verify the installer cannot drift from the canonical app identity. This also
# renders the background and reads it back with Apple's text recognition: it
# fails if the window would show anything but its two lines of words. It
# gives a scratch folder the Legal folder's icon, as a build does.
./scripts/build-installer.sh --verify-assets

# See the window: background.png, legal-icon.png and window.png, a mock-up
# of the whole window laid out from layout.json. Nothing opens in Finder.
./scripts/build-installer.sh --preview /tmp/installer-window
```

The generators use the Python standard library and macOS's own frameworks
through `xcrun swift`; nothing else is installed. Every build renders the
background into the image from current source.

| Asset | Source | Generator |
|---|---|---|
| `assets/installer/layout.json` | The window: its frame, the title bar's height, the icon and text sizes and each item's position | edited by hand; read by everything below |
| `assets/installer/background.png` | The hi mark's tile gradient, the words and the arrow, drawn by `render-background.swift` from `layout.json` | `generate-background.py` |
| Legal folder icon | A small page in the tile's colours, drawn by `render-legal-icon.swift` | applied by the build on the mounted image |
| `assets/installer/EULA.rtf` | `docs/legal/terms-of-service.md` | `generate-eula.py` |
| `assets/installer/volume-icon.icns` | `assets/branding/AppIcon.icns` | verified mirror; the build stages the canonical file directly |

### The installer window

The window's saved size is its frame, and the title bar (32 points on
macOS 26, 28 on 14 and 15) can take part of it. So the background is drawn
at the full 640x432 frame and everything a person reads sits in the 400
points below the title bar: whichever way Finder counts, there is no blank
strip and no word is cut off. The app is on the left and Applications on
the right, 112-point icons facing each other across the middle, with "Drag
to Applications" and the arrow between them. `dmg-layout.py` writes
Finder's metadata from `layout.json`, and `scripts/test-installer-layout.py`
checks that every icon and name fits that area, that nothing overlaps, and
that every rendered word sits clear of the icons and their names.

### What the DMG contains

- `Hippocampus.app` — the application bundle
- `Applications` symlink — drag-target for installation
- `Legal/License.rtf` — the canonical software license terms; the folder
  shows as a small page, so the only folder in the window is Applications
- `.background/background.png` — branded Finder background (hidden, 1280x864 at 144 dpi)
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
shasum -a 256 -c dist/Hippocampus-<version>.dmg.sha256

# Verify Gatekeeper acceptance (Developer ID builds)
spctl --assess --type open --context context:primary-signature \
  --verbose dist/Hippocampus-<version>.dmg

# Verify notarization staple
stapler validate dist/Hippocampus-<version>.dmg
# Expected: "The validate action worked!"

# Inspect codesign details
codesign -dv --verbose=4 Hippocampus.app
```

### CI release workflow

The release normally runs on this Mac (`release-0.3.0.sh`, above). Tagged
pushes (`v*`) also trigger `.github/workflows/release.yml`; with no release
secret set it builds nothing. With all six it:
1. Freezes tag, bundle, changelog, feed, and model identity.
2. Reconstructs the hash-pinned model archive and builds every Swift/Rust binary.
3. Imports Developer ID, notarization, and matching Sparkle credentials.
4. Signs, notarizes, staples, and verifies the app and outer DMG.
5. Writes and signs the release's appcast (`scripts/sparkle-publish.sh`) and
   verifies it.
6. Uploads the DMG, checksum, and appcast to a draft GitHub release only.

The app's update feed is the newest published release's `appcast.xml`, so the
separate owner-triggered `.github/workflows/publish-release.yml` re-verifies
the inspected draft, promotes it to Latest, and checks the live feed.

Required GitHub secrets for signed releases:

| Secret | Description |
|---|---|
| `APPLE_CERTIFICATE_P12` | Base64-encoded `.p12` Developer ID Application certificate |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` file |
| `NOTARYTOOL_APPLE_ID` | Apple ID email for notarization |
| `NOTARYTOOL_TEAM_ID` | Apple Developer Team ID |
| `NOTARYTOOL_PASSWORD` | App-Specific Password for notarization |
| `SPARKLE_PRIVATE_KEY` | Sparkle private seed matching `SUPublicEDKey` |

The model archive's URL and SHA-256 come from the committed
`release-models.json`, not from repository variables. If any credential is
absent, or the manifest does not name the tag's version, release packaging
fails closed.

---

## demo.sh

A demo of the whole product on synthetic data, in a disposable folder under
`$TMPDIR` (or `MCI_DEMO_ROOT`), never the real memory. Its subcommands, from
the script's header:

| Command | What it does |
|---|---|
| `clean` | Stops the demo's own processes and wipes only the disposable demo folder |
| `seed` | Makes a throwaway key and seeds 20 synthetic events |
| `boot` | Builds Hippocampus.app, embeds Sparkle, signs it and opens it |
| `query` | Runs canned `mci-brain` searches against the seeded memory |
| `mcp-demo` | Sends `mci_recall` over JSON-RPC to a running `mcp-serve` |
| `screenshot` | Captures the demo's windows (`screencapture -w`, interactive; `--auto` renders the CLI and tries the windows) |
| `teardown` | Stops the demo's processes and deletes the demo folder |
| `full` | All of the above, in order |

```bash
./scripts/demo.sh full
./scripts/demo.sh seed && ./scripts/demo.sh query
```

Every file it makes stays under the demo folder (mode 0700), the key never
reaches shell history, and the seeded events are made up
(`com.mci.demo.seed.*`).
