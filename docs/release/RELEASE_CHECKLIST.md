# Release checklist

The blocking list for a public Hippocampus release. A local ad-hoc build is a development copy, never a release. The steps follow `scripts/release-0.3.0.sh`, which builds, signs, notarizes and checks a release on this Mac; [docs/appcast-hosting.md](../appcast-hosting.md) says how updates reach installed copies.

## Before the build

- [ ] On the release branch the script names (`RELEASE_BRANCH`), with a clean tree.
- [ ] `CHANGELOG.md` has a dated `## [x.y.z]` section. The appcast shows it as the update's notes, and What's New shows it in the app, so every line is for the person using it.
- [ ] `docs/release/notes-x.y.z.md` exists and holds `{{SHA256}}`.
- [ ] `docs/STATUS.md` says what was checked, and how, at this commit. The release script stamps its baseline line.
- [ ] `scripts/check.sh` passes in full on a quiet Mac. Keep the log.
- [ ] The OCR worker matches `tools/ocr` (`tools/ocr/.venv/bin/python tools/ocr/prepare.py`). The release script rebuilds a stale one by itself.
- [ ] The copyleft libraries in the OCR worker that NOTICE lists have their source attached to the release, or a written offer in NOTICE. This needs the owner's decision.

## Build, sign and notarize

```bash
scripts/release-0.3.0.sh --check     # every quick gate; changes nothing
scripts/release-0.3.0.sh --dry-run   # optional: builds and signs here, notarizes nothing
scripts/release-0.3.0.sh --notes docs/release/notes-0.3.0.md
```

The script stops at the first failure. It checks, among other things:

- [ ] `codesign --verify --deep --strict` on the app, the app inside the DMG and the DMG.
- [ ] Gatekeeper and `stapler validate` on the stapled DMG and app.
- [ ] `syspolicy_check distribution` on the app.
- [ ] Both notary logs: Accepted, with no issues (`scripts/check-notary-log.py`).
- [ ] `hippocampus-mind` links Foundation Models weakly, and every binary runs on macOS 14 (`scripts/verify-release-app.sh`).
- [ ] `appcast.xml` and its signatures, against `SUPublicEDKey` (the staged identity gate).

Record the DMG and app sizes it prints in `docs/STATUS.md`.

## Before publishing

- [ ] On a new macOS user: download, the four setup screens, Shift twice, Stop Sharing, and Quit leaving nothing running (`scripts/verify-quit-leaves-nothing.sh`).
- [ ] An update from the previous public version keeps the Keychain key and the capture choice.
- [ ] Gatekeeper accepts a freshly downloaded copy on a second Mac.
- [ ] On macOS 14 or 15, if one is at hand: the app starts and says answers need Apple Intelligence or a model on the Mac.

## Publish

- [ ] Push the release commit. Create a draft release at it with every file the script lists: `Hippocampus-x.y.z.dmg` and its `.sha256`, `Hippocampus.dmg` and its `.sha256`, `appcast.xml` and `install.sh`, with the filled `release-notes.md` as its notes.
- [ ] Inspect the draft ([appcast-hosting.md](../appcast-hosting.md#inspect)). Never edit `appcast.xml` by hand: its signature covers its bytes.
- [ ] Publish it as Latest (`gh release edit vx.y.z --draft=false --latest`, or the Publish inspected release workflow). Latest is the update feed; a draft or a prerelease changes nothing for installed copies.
- [ ] Check the public state: the appcast URL serves this release's `appcast.xml`, `releases/latest/download/Hippocampus.dmg` downloads it, and the one-line installer installs it on a clean account.
- [ ] Homebrew: in the `amyjainberkeley/homebrew-tap` repository, run `./update-cask.sh <notarized DMG>`, push, and try `brew install --cask amyjainberkeley/tap/hippocampus` on a clean account.
- [ ] Record the release commit, the checksums, the notary submission IDs, and the Mac and macOS version of each smoke test. Never record a secret.

## Privacy and memory

These hold for every release. Each has tests; the last four need a person on a real Mac.

- [ ] Capture off starts no stream, no reading and no screenshot writer, and asks for no screen permission.
- [ ] Remembering shows only after the helper reports that its streams started.
- [ ] Skipped windows never reach the reader or the store.
- [ ] Screenshots open only with their key; plaintext, wrong-key, missing and corrupt files fail closed.
- [ ] Claude Code and Codex settings hold a Keychain reference, never a key.
- [ ] A memory from the previous version keeps working after the update, with its key in the Keychain.
- [ ] Delete the last 24 hours, and delete everything, leave nothing of those moments in the database or the screenshot folder.
- [ ] Quit, and Stop Sharing, stop everything Hippocampus started.
- [ ] Private windows in Safari, Chrome, Arc, Firefox, Edge and Brave are skipped when they show they are private.

## From CI instead

A `v*` tag runs `.github/workflows/release.yml`. With no release secret set it builds nothing; with all six it builds, signs, notarizes, writes the appcast and creates a draft. It downloads the model archive named in `release-models.json`, which must then name real bytes. Publication is the same as above. [appcast-hosting.md](../appcast-hosting.md#release-from-ci) has the one-time setup.
