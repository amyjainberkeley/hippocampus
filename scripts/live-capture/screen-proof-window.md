# Screen-Only Qualification Window

This standalone native fixture is not shipped in Hippocampus. It has no brain,
Keychain, capture, import or network access. It generates twelve random words
only when **Generate once** is clicked while the application is active and its
window is key. Twelve independent selections from 32 words provide 60 bits of
randomness. The plaintext exists in the fixture's memory and visible text;
there is no document-save or clipboard-export operation. Window restoration is
disabled. The receipt prints only the phrase's SHA-256, timestamp and focus
booleans. Subsequent content-free receipts record sampled foreground duration.
The counter requires an active application, key visible window and focused
text field; it resets on focus loss or a sampling gap over two seconds. The
receipt is not proof of subsequent capture, storage or image readback.

Build a disposable app from `ScreenProofWindow.swift` and the companion plist:

```sh
mkdir -p '/tmp/Hippocampus Screen Proof.app/Contents/MacOS'
xcrun swiftc -swift-version 6 -O scripts/live-capture/ScreenProofExposure.swift \
  scripts/live-capture/ScreenProofWindow.swift \
  -o '/tmp/Hippocampus Screen Proof.app/Contents/MacOS/ScreenProofWindow'
cp scripts/live-capture/ScreenProofWindow-Info.plist \
  '/tmp/Hippocampus Screen Proof.app/Contents/Info.plist'
codesign --force --sign - '/tmp/Hippocampus Screen Proof.app'
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  '/tmp/Hippocampus Screen Proof.app/Contents/MacOS/ScreenProofWindow'
```

Do not print, paste into the agent conversation or import the generated phrase.
Bring the fixture to the real foreground and leave the words visible through
the capture interval. The foreground counter must reach 20 seconds. Its sampled
observations do not establish uninterrupted visibility between samples. Search
and inspection must use actual newly captured
evidence, not a fixture-store seed. Before using an external AI client, confirm
that the destination is one the owner approved.

For validation, normalize only the displayed line breaks to spaces and compare
SHA-256 with the receipt. Require the same phrase in fresh screen-origin text
and its authenticated image. Close this window before restarting Recall and
reopening the linked image. No manual source-kind rewrite, relaxed admission
policy, stale event, image from another record or rising aggregate counter can
pass the [product gate](../../docs/audits/2026-09-07-observable-gates.md).

The earlier `verify_production_memory.py` uses fixed probes and cannot read
images. It remains available for its original bounded text check; do not call
it a validator for this random screen-only fixture.

The exposure calculation is independently executable without opening a window:

```sh
xcrun swiftc -swift-version 6 scripts/live-capture/ScreenProofExposure.swift \
  scripts/live-capture/ScreenProofExposureTests.swift -o /tmp/screen-proof-exposure-tests
/tmp/screen-proof-exposure-tests
```
