# Hippocampus.entitlements — audit notes

`Hippocampus.entitlements` is the hardened-runtime entitlement set embedded into the signed `Hippocampus.app` and its main executable. The capture helper uses the separate, narrowly scoped `MCICaptureHelper.entitlements` in this directory. The plist files contain **no XML comments** because `AMFIUnserializeXML` (the codesign-side parser) rejects in-body comments and aborts with `syntax error near line 5`. Documentation lives here instead.

Each key, in the order it appears in the plist:

| Key | Value | Why |
|---|---|---|
| `com.apple.security.cs.allow-jit` | `false` | JIT compilation is not used. Stated explicitly for audit clarity (false is the hardened-runtime default). |
| `com.apple.security.cs.allow-unsigned-executable-memory` | `false` | No unsigned executable memory is needed; all code is AOT-compiled. |
| `com.apple.security.cs.allow-dyld-environment-variables` | `false` | No DYLD env overrides in production. |
| `com.apple.security.automation.apple-events` | `true` | Allows the principal/responsible parent to request Automation consent for browser context queries made by its capture helper. Consent remains controlled by macOS and the user. |
| `com.apple.security.application-groups` | rendered at assembly | **REQUIRED for the Safari Web Extension `.appex`** to relay page content events to the container app via a shared App Group container. The checked-in `group.ai.hippocampus` value is a template used by ad-hoc builds. Developer ID assembly replaces it in both host and `.appex` with `<TeamIdentifier>.ai.hippocampus`, then verifies the signed entitlements and bundle configuration agree. |

The App Group is intentionally granted only to the host app and Safari
extension. The capture helper, agent, Recall UI, onboarding process, and
Chromium native host do not need shared-container access and are signed without
it. V1's Developer ID route uses Apple's supported macOS-only
`<TeamIdentifier>.<group name>` convention, which does not require a
provisioning profile. Ad-hoc assembly verifies structure but does not establish
a release-grade App Group container. A future cross-platform `group.` identity
must be registered and authorized by profiles embedded in both bundles; Apple
also recommends profiles for stronger entitlement validation on current macOS.

## Apple Events signing contract

The capture helper sends Apple events through `NSAppleScript` to read the active
browser URL and determine whether a Chromium window is normal or private for
private-window exclusion. Both the responsible parent (`ai.hippocampus`) and
the actual sender (`MCICaptureHelper`) carry
`com.apple.security.automation.apple-events = true`. The helper's entitlement
file contains only this key, with no App Group or Keychain access groups.
The agent, Recall UI, onboarding process, Chromium native host, and Safari
extension receive no Apple Events entitlement.

Apple's [Apple Events entitlement reference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)
describes the entitlement as enabling permission requests to send Apple events
to other apps. The same-team exception does not cover external browsers.
Apple also requires [NSAppleEventsUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)
for APIs that send Apple events. The purpose string in the responsible parent's
`Info.plist` explains URL access, normal/private-window classification, exclusion
of private windows, local memory, and sharing only when the user chooses it.
The helper is an executable inside this app bundle, not a separate app bundle.

Assembly signs the helper with its own file in both Developer ID and explicit
development ad-hoc modes. Installer Developer ID re-signing supplies that same
file again; its ad-hoc path verifies the existing assembly signature. The parent
keeps its separately rendered App Group entitlement in both signing stages.
Production signing retains `--options=runtime` and timestamps, following Apple's
[hardened runtime guidance](https://help.apple.com/xcode/mac/current/en.lproj/devf87a2ac8f.html).
Neither entitlement file enables `get-task-allow`, JIT, unsigned executable
memory, DYLD overrides, or disabled library validation.

This entitlement permits a consent request; it does **not** preauthorize
Automation, override a denial, reset TCC, or bypass macOS permission checks.
This signing fix makes no OS permission changes.

### Evidence and verification

The initial missing-entitlement diagnosis was inferred from the installed
parent/helper signature dumps and Apple's API requirements. Runtime evidence
supplied by the parent task subsequently confirmed the failure: the
`com.apple.TCC` log at `2026-09-05 04:56:11.770` reported that hardened-runtime
prompting for `kTCCServiceAppleEvents` requires
`com.apple.security.automation.apple-events`, missing for responsible
`ai.hippocampus` PID `77020` at
`/Applications/Hippocampus.app/Contents/MacOS/Hippocampus`, with accessing
`MCICaptureHelper` PID `77028`. The subsequent entry said policy disallowed the
prompt and denied Apple Events access. This is a confirmed pre-fix prompting
denial, not verification that a corrected installed build prompts successfully.

Run `python3 -B scripts/test_apple_events_signing_contract.py` for the focused
source and signing checks. `scripts/test-app-group-contract.sh` also invokes it
so the existing signing-contract CI gate covers this entitlement. The test
checks scope, hardening, purpose-string concepts, and both scripts' signing
arguments. On macOS it signs disposable copies of `/usr/bin/true` using those
arguments, replacing the Developer ID with an ad-hoc identity and disabling
timestamp-service access, then reads the signed entitlements and runtime flags
after assembly and installer re-signing. It also verifies the development
ad-hoc path. No fixture is launched; these checks do not establish Developer ID
trust, notarization, successful OS prompting, or ordinary browser capture.

## Why `com.apple.security.cs.disable-library-validation` was REMOVED

Earlier revisions of this file set `disable-library-validation = true` on the grounds that Sparkle 2.x ships its own pre-signed binaries (XPC services + Updater.app + Autoupdate). The reasoning was: Sparkle's signatures don't match the host app's Team ID, so the hardened runtime's library-validation policy would reject them at load time.

That reasoning is **wrong for our build**. Our `build-app.sh` re-signs every Sparkle binary with our Developer ID ([redacted], [REDACTED-TEAMID]) inside-out before the outer .app is signed. After re-signing, every nested Mach-O / bundle has the SAME Team ID as the host — so library validation passes by default. The exemption was treating a symptom that no longer existed.

Why this matters: Apple's [Disable Library Validation Entitlement reference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation) states *"Because library validation is such an important security-hardening feature, Gatekeeper runs extra security checks on programs that have it disabled."* In particular, Apple devforum thread [132908](https://developer.apple.com/forums/thread/132908) and [711769](https://developer.apple.com/forums/thread/711769) document the exact "developer cannot be verified" Gatekeeper dialog firing on apps that carry this entitlement unnecessarily. A friend's test on 2026-05-26 reproduced the dialog despite a fully-stapled, notarized build; removing this entitlement is the highest-leverage fix.

The Sparkle sandboxing doc (<https://sparkle-project.org/documentation/sandboxing/>) prescribes additional entitlements (`mach-lookup`, the `Downloader.xpc` no-network-client preservation, etc.) **only when the host app is sandboxed**. Hippocampus is not sandboxed (we run as a menu-bar agent that supervises a TCC-privileged helper). The full sandboxed-host entitlement set doesn't apply here.

If a future change adds a third-party-Team-ID dylib (e.g., bundling a closed-source SDK), library validation will need to be disabled again — but scope it to that binary only (per-binary entitlements) rather than putting it on the host app.

## Why comments are stripped from the plist

The codesign tool ultimately passes the entitlement plist through `AMFIUnserializeXML`, the same parser the macOS kernel uses to validate code signatures at load time. AMFI's parser is stricter than `plutil` — in particular, it rejects XML comments (`<!-- ... -->`) anywhere inside the `<plist>` body. The build aborts with:

```
Failed to parse entitlements: AMFIUnserializeXML: syntax error near line 5
```

`plutil -lint` and most editors accept the comments, which is what makes this footgun easy to step on. Keep documentation in this file; keep the entitlements plist comment-free.

## Related files

- [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups) and [Accessing app group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers) — Apple's current identity and provisioning rules.
- `extensions/safari/appex/HippocampusSafariExtension.entitlements` — entitlements for the embedded Safari `.appex` (also comment-free).
- `apps/hippocampus/Resources/MCICaptureHelper.entitlements`: Apple Events entitlement for the capture helper only.
- `scripts/lib/app-group-contract.sh` — derives, renders, and validates the shared identity.
- `scripts/build-installer.sh` — preserves and re-verifies the identity while producing the installer.

## Review history

- 2026-05-22 (PR #155): stripped 6 in-body XML comments that aborted the first Developer-ID-signed installer build. Functional entitlements unchanged. Added `application-groups` (already present pre-strip from PR #148) carried forward intact. No new entitlements granted.
- 2026-05-26 (this commit): removed `com.apple.security.cs.disable-library-validation`. See section above for rationale. Reproduces the "developer cannot be verified" Gatekeeper dialog on stapled+notarized builds per Apple devforum 132908 / 711769; root cause for friend's tester 2026-05-26.
