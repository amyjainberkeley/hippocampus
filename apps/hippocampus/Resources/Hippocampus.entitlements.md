# Hippocampus.entitlements — audit notes

`Hippocampus.entitlements` is the hardened-runtime entitlement set embedded into the signed `Hippocampus.app` (main binary + helpers). The plist file itself contains **no XML comments** because `AMFIUnserializeXML` (the codesign-side parser) rejects in-body comments and aborts with `syntax error near line 5`. Documentation lives here instead.

Each key, in the order it appears in the plist:

| Key | Value | Why |
|---|---|---|
| `com.apple.security.cs.allow-jit` | `false` | JIT compilation is not used. Stated explicitly for audit clarity (false is the hardened-runtime default). |
| `com.apple.security.cs.disable-library-validation` | `true` | **REQUIRED for Sparkle 2.x.** Sparkle embeds XPC services and dynamically loads its Autoupdate bundle. Without this entitlement the hardened runtime rejects Sparkle's code signature (Sparkle's bundles are signed under Sparkle's identity, not ours). See <https://sparkle-project.org/documentation/sandboxing/>. |
| `com.apple.security.cs.allow-unsigned-executable-memory` | `false` | No unsigned executable memory is needed; all code is AOT-compiled. |
| `com.apple.security.cs.allow-dyld-environment-variables` | `false` | No DYLD env overrides in production. |
| `com.apple.security.application-groups` | `["group.ai.hippocampus"]` | **REQUIRED for the Safari Web Extension `.appex`** to relay page content events to the container app via a shared App Group container. Mirrors the `.appex`'s own entitlements file at `extensions/safari/appex/HippocampusSafariExtension.entitlements`. |

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

- 2026-05-22 (this commit): stripped 6 in-body XML comments that aborted the first Developer-ID-signed installer build for team `[REDACTED-TEAMID]`. Functional entitlements unchanged. Added `application-groups` (already present pre-strip from PR #148) carried forward intact. No new entitlements granted.
