# extensions/

Browser extensions that ship active-tab URL + focused-page content
to `apps/hippocampus-native-host/` via the native-messaging protocol.
One extension per browser, sharing a minimal common shape.

## Contents

- `chromium/` — Chrome / Edge / Brave / Arc extension (Manifest V3).
- `safari/` — Safari extension packaged as a Web Extension App
  Extension (`appex/`) inside the Hippocampus `.app` bundle.

## Related

- `../apps/hippocampus-native-host/` — the Rust binary these
  extensions talk to. All content is filtered there before it hits
  the agent.
- `../docs/research/browser-extension-audit.md`.
- `../scripts/generate-extension-toolbar-icons.py` — icon
  regeneration.

## When to edit here

Per-browser extension surface: content scripts, background scripts,
manifest, permission scopes. Anything crossing the process boundary
into MCI belongs in `../apps/hippocampus-native-host/` (framing,
secret filtering) — extensions must stay dumb. Adding a new browser
means adding a sibling directory here + a matching handshake in the
native host.
