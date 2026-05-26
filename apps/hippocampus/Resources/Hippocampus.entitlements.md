# Hippocampus.entitlements — audit notes

`Hippocampus.entitlements` is the hardened-runtime entitlement set embedded into the signed `Hippocampus.app` (main binary + helpers). The plist file itself contains **no XML comments** because `AMFIUnserializeXML` (the codesign-side parser) rejects in-body comments and aborts with `syntax error near line 5`. Documentation lives here instead.

Each key, in the order it appears in the plist:

| Key | Value | Why |
|---|---|---|
| `com.apple.security.cs.allow-jit` | `false` | JIT compilation is not used. Stated explicitly for audit clarity (false is the hardened-runtime default). |
| `com.apple.security.cs.allow-unsigned-executable-memory` | `false` | No unsigned executable memory is needed; all code is AOT-compiled. |
| `com.apple.security.cs.allow-dyld-environment-variables` | `false` | No DYLD env overrides in production. |
| `com.apple.security.application-groups` | `["group.ai.hippocampus"]` | **REQUIRED for the Safari Web Extension `.appex`** to relay page content events to the container app via a shared App Group container. Mirrors the `.appex`'s own entitlements file at `extensions/safari/appex/HippocampusSafariExtension.entitlements`. |

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

- `extensions/safari/appex/HippocampusSafariExtension.entitlements` — entitlements for the embedded Safari `.appex` (also comment-free).
- `adapters/macos/MCICaptureHelper/Resources/MCICaptureHelper.entitlements` — entitlements for the capture helper (if present; check before any future edit).
- `scripts/build-installer.sh` lines 152–196 — where codesign is invoked with `--entitlements` for each component.

## Review history

- 2026-05-22 (PR #155): stripped 6 in-body XML comments that aborted the first Developer-ID-signed installer build. Functional entitlements unchanged. Added `application-groups` (already present pre-strip from PR #148) carried forward intact. No new entitlements granted.
- 2026-05-26 (this commit): removed `com.apple.security.cs.disable-library-validation`. See section above for rationale. Reproduces the "developer cannot be verified" Gatekeeper dialog on stapled+notarized builds per Apple devforum 132908 / 711769; root cause for friend's tester 2026-05-26.
