# `tools/probe-harness/` — STEP-2-FINDING-001 §4 isolation surface

A tiny throw-away Cocoa Swift app. One window. One `NSSecureTextField`
(plus a plain `NSTextField` for an A/B comparison). **No** explicit
`EnableSecureEventInput()` call anywhere in the binary.

This is dev-tooling. Not part of `mci-capture-helper`. Not signed.
Not notarized. Not distributed.

## Why this exists

`docs/audit/2026-05-19-step2-sec-7-corpus.md` filed
**STEP-2-FINDING-001**: on macOS 26 Tahoe, the ADR-0013 cascade §4
probe (`AXSubroleProbe.focusedHasSecureSubrole()`) returned `false` /
`nil` on every System Settings password sheet + 1Password
master-password + `sudo` focus — despite the helper's host process
holding a confirmed Accessibility TCC grant.

The finding listed five fault surfaces. Two are structural and
cannot be told apart on naturally-paired secure-field surfaces:

- **Suspect (1):** macOS 26 SwiftUI / Catalyst password fields no
  longer expose `kAXSecureTextFieldSubrole` via the AX bridge.
  System Settings + 1Password are both modern UIs and would both
  exhibit the regression.
- **Suspect (5):** Cascade order is `§1 → §2 → §3 → §4`. **Any** app
  that focuses a real `NSSecureTextField` also flips the process-wide
  Carbon secure-event-input bit (§3) — Cocoa's `NSSecureTextField`
  calls `EnableSecureEventInput()` internally when its field editor
  takes focus. The cascade's first-match-wins ordering means §3 fires
  before §4 is consulted, so §4 looks "dead" in every naturally-paired
  secure-field scenario *even if the probe is fine*.

The probe-harness is the **isolated-§4 surface** the finding called
for. It deliberately avoids any explicit `EnableSecureEventInput()`
call so the test author's intent — "exercise the §4 path alone" — is
visible in source. The remaining "did §3 still trip anyway?" question
is then exactly the diagnostic data the human Step-2 re-run needs:

- §3 fires + §4 fires → probe is fine, cascade-short-circuit suspect
  (5) is the structural confound, naturally-paired scenarios will
  always look dead; the corpus protocol grows an isolated-§4 entry.
- §3 fires + §4 does NOT fire → suspect (1) is real *and* the probe
  is implicated; suspect (5) alone does not explain it. Add the
  identifier / title / role heuristic backstop discussed in the
  finding.
- §3 does NOT fire + §4 fires → §3 is somehow not auto-enabled in
  this surface (rare); §4 is fine.
- §3 does NOT fire + §4 does NOT fire → §4 is broken AND something
  about NSSecureTextField on macOS 26 also no longer auto-enables
  Carbon secure-event-input. Both are real findings.

## Important honesty note on `NSSecureTextField` auto-behavior

The task brief for this harness asked for `NSSecureTextField` with
`EnableSecureEventInput()` "deliberately omitted." This binary does
omit any explicit call — but `NSSecureTextField` is an Apple-shipped
widget whose private machinery may still call `EnableSecureEventInput`
under the hood when the field becomes first responder in a key
window. We deliberately did **not** override or subclass to suppress
that — overriding the field would change what we're testing
("does the cascade catch a real `NSSecureTextField`?"). If `--capture
--probe-debug` runs against this harness and the wire stream shows
§3 (`reason=3`) frames, that itself is the answer to one of the
suspect-(5) questions and the harness has done its job. If the
isolated-§4 corpus entry the finding talks about requires a §3-free
widget, the next harness iteration will replace `NSSecureTextField`
with a plain `NSView` whose `accessibilitySubrole` is overridden to
`.secureTextField` and which never enables Carbon secure input. That
is **not** what this PR delivers — this PR delivers the simplest
hairier-than-`NSTextField` isolation that the brief described.

## How to use

```sh
# 1. Build + run the harness (foreground; closes the window to quit).
cd tools/probe-harness
swift build
.build/debug/ProbeHarness &
HARNESS_PID=$!

# 2. In a separate terminal: build + run the helper with --capture
#    --probe-debug. Plain Terminal.app (NOT tmux) — TCC is per-app.
cd adapters/macos/MCICaptureHelper
swift build
.build/debug/mci-capture-helper \
    --capture \
    --probe-debug \
    --output /tmp/mci-finding-001.bin \
    --heartbeat-seconds 5 \
    2> /tmp/mci-finding-001.stderr

# 3. Switch to the ProbeHarness window (it should be frontmost
#    automatically). Click the secure field. Type a few characters.
#    Click the plain field. Type. Cmd-Q to quit the harness.

# 4. Stop the helper (Ctrl-C). Read the diagnostic streams:
grep "probe(ax-subrole)" /tmp/mci-finding-001.stderr | head
python3 tools/wire_decode.py /tmp/mci-finding-001.bin | grep -E "reason"
```

Expected `--probe-debug` shape per probe call (one line):

```
mci-capture-helper: probe(ax-subrole) focus=success role=AXTextField subrole=AXSecureTextField id=mci-probe-harness-secure-field title=nil result=true
```

(The exact role / id / title / result depend on what AX reports for
the focused element on macOS 26. That is what the harness is here to
discover.)

## Why not unit-test this instead

Because the whole point of STEP-2-FINDING-001 is that the AX query
behaviour on macOS 26 disagrees with the unit-test stub's behaviour.
Headless `xctest` runs without AX permission and `AXUIElementCopyAttributeValue`
returns `.apiDisabled` (cascade fail-safe). The pure classifier is
already unit-tested in
`adapters/macos/MCICaptureHelper/Tests/MCICaptureHelperKitTests/AXSubroleProbeClassifyTests.swift`.
What we cannot test headlessly is "does macOS 26's *real* AX bridge
hand us back `kAXSecureTextFieldSubrole` when we focus a real
`NSSecureTextField`?" — and that is what this harness exists to
answer on a real Mac.

## Not for distribution

- Local-only build (`swift build`).
- No code-signing or notarization.
- No entitlement plist.
- Will not pass App Sandbox.
- Will be deleted after STEP-2-FINDING-001 closes.
