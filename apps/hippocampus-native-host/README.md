# apps/hippocampus-native-host/

Rust binary that speaks Chrome/Safari's native-messaging protocol:
the bridge between the browser extensions in `../../extensions/` and
`mci-agent`. Applies the secret-filter policy before any page
content or tab metadata crosses the process boundary.

## Contents

- `src/main.rs` — the shipping binary. Reads length-prefixed JSON
  frames on stdin, forwards to the agent, writes replies to stdout.
- `src/secret_filter.rs` — regex / heuristic filter that drops
  API keys, tokens, and other high-entropy secrets before ingest.
- `Cargo.toml` — the `mci-hippocampus-native-host` package
  manifest.

## Related

- `../../extensions/chromium/`, `../../extensions/safari/` — the
  browser extensions that connect to this host.
- `../agent/` — the Rust agent that receives forwarded frames.
- `../../docs/research/browser-extension-audit.md`.

## When to edit here

Native-messaging framing changes, secret-filter rules, and the
extension ↔ agent wire schema. Anything that changes what the
browser extensions actually capture (DOM selectors, page-content
extraction) belongs in `../../extensions/<browser>/`, not here.
Secret-filter changes are CSO-gated (they gate exfiltration risk).
