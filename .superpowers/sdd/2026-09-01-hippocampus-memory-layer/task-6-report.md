# Task 6 Report: Evidence-Backed Agent Context

Date: 2026-09-01

## Result

PASS for implementation and hermetic verification. The signed production-bundle
smoke remains externally gated and is not counted as passing.

## Delivered

- `mci_context` is the sixth read-only MCP tool. It compiles a fixed hierarchy:
  current state, changes, decisions, open loops, people, and evidence.
- Governed assertions require an active claim, confidence at or above 0.65,
  readable canonical event evidence, and no unresolved same-key contradiction.
  Superseded, contradicted, weak, missing-evidence, or out-of-focus claims do not
  become facts.
- Every grounded item carries a stable claim id and canonical event ids. Every
  citation carries timestamp and source metadata. Raw retrieval candidates are
  labeled observations, never promoted to claims.
- Packet construction is deterministic and model-free. Caller budgets are
  clamped by MCP to 128..4096 estimated tokens and 1..64 distinct citations.
  The compiler also enforces a UTF-8 byte ceiling and continues after an item
  does not fit, preventing one-item starvation.
- `focus` and the compatibility alias `project` both focus claim selection and
  typed recall candidates. Empty focus uses a bounded recent-event window.
- `mci-agent connect --all` registers detected Claude Code and Codex clients.
  `init` calls the same registry only after key initialization, brain open,
  import, and enrichment succeed. `register-mcp` remains a one-release
  Claude-only compatibility command.
- Claude JSON and Codex TOML are patched structurally. Codex comments and
  unrelated formatting survive. Existing unrelated servers named
  `hippocampus` produce a name conflict rather than being overwritten.
- Config updates preserve valid dotfile-manager symlinks and existing modes;
  refuse dangling symlinks, non-regular targets, foreign ownership, and hard
  links; serialize Hippocampus writers with an advisory lock; compare before
  commit; write collision-resistant exclusive temp files; fsync file and
  parent; rename atomically; and verify the committed semantics.
- Generated entries contain exactly command, `args=["mcp-serve"]`, database
  path, Keychain service, Keychain account, and storage model. Raw or
  development key fields are absent. Parser diagnostics do not include config
  source text.
- The native menu and onboarding use one client-neutral Connect AI Tools action
  and invoke `connect --all`. Both affected Swift packages compile.

## Verification

The focused Task 6 integration batch passed 109 tests:

```text
cli_unknown_command          5 passed
client_registration_e2e      1 passed
client_registry             16 passed
context_packet              12 passed
mcp_e2e_real_brain          34 passed
mcp_server                  28 passed
register_mcp                13 passed
```

Additional gates:

```text
cargo clippy -p mci-agent --all-targets --all-features --locked -- -D warnings
  PASS

cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
  PASS

cargo test --workspace --all-features --locked
  PASS

cargo fmt --all -- --check
  PASS

scripts/swift-package.sh build --package-path apps/onboarding
  PASS

scripts/swift-package.sh build --package-path apps/hippocampus
  PASS

scripts/test-swift-package.sh
  25 passed, 0 failed
```

The repository's Swift package test wrappers reach compilation but cannot run
XCTest on this host because only Command Line Tools are installed (`no such
module XCTest`). Both production package builds pass, so this is recorded as an
external toolchain gate rather than a passing test claim.

The reconstructed-command E2E creates an isolated HOME and synthetic stable app
bundle, registers twice, proves byte and modification-time no-op behavior,
parses each client independently, launches each generated command with
`env_clear`, initializes MCP, lists `mci_context` exactly once, calls it with a
project focus, checks typed output, and bounds/reaps both child processes.

An additional disposable-home probe passed the directly generated Codex TOML
to the installed Codex CLI. Both `codex mcp get hippocampus --json` and
`codex mcp list --json` accepted the entry and reported exactly the generated
stdio command, one argument, and four content-free environment fields. No real
Claude or Codex user configuration was read or modified.

## External Gate

The signed-bundle production smoke was not run. This host reports zero valid
code-signing identities and has Command Line Tools rather than full Xcode.
Signing, notarization, and a real login-Keychain launch from the stable signed
bundle remain Task 8 owner/environment prerequisites. The implementation does
not claim those gates passed.
