# apps/agent/BEST_PRACTICES.md

Subtree invariants for the `mci-agent` binary. Read the top-level
`BEST_PRACTICES.md` first; this file adds agent-binary contracts
derived from PR #73 and the supervision-tree work.

## Purpose

`mci-agent` is the long-running Rust parent process: it supervises
the capture helper, hosts the MCP server surface, and coordinates
async workers. Behavior at process boundaries (exit codes, IPC
error handling, MCP tool responses) is the load-bearing contract
consumed by the SwiftUI shell and by external MCP clients.

## Rules

1. **ExitCode discipline.** `mci-agent` uses a documented ExitCode
   space so the Hippocampus supervisor can distinguish "clean stop",
   "crash — restart", "corruption — do NOT restart", and "config
   invalid". Never `std::process::exit(1)` on an ambiguous error;
   route through the ExitCode enum in `main.rs`.

2. **Refuse-to-serve on integrity failure (PR #73).** If the brain
   store fails `PRAGMA integrity_check` at startup, the agent MUST
   refuse to serve queries — return a typed MCP error, do not
   fall back to a fresh empty store. See top-level rule 1 and
   `core/brain/BEST_PRACTICES.md`.

3. **MCP tool surface stability.** Tools exposed by `src/mcp/`
   form a public contract for external clients (Claude Desktop, IDE
   agents, etc.). Renaming or removing a tool is a breaking change;
   version the surface via ADR before shipping.

4. **Supervisor decides restart policy, not workers.** Workers
   under `src/*_worker.rs` return typed errors upward; only
   `supervisor.rs` / `pump_supervisor.rs` decide whether to restart.
   A worker that self-heals hides supervision signal from the tree.

5. **Panic hook is load-bearing.** `panic_hook.rs` +
   `panic_uploader.rs` MUST be installed before any worker spawns;
   a panic that bypasses the hook produces an unrecoverable
   crash-loop with no diagnostic. Do not disable panic capture in
   release builds "to reduce noise."

6. **Seeders refuse non-empty brains.** `mci_seed_brain` and
   `mci_seed_brief` are demo-only and MUST verify the target
   brain is empty before writing. Never remove that guard.

7. **Device ID never leaves the device.** `device_id.rs` is
   consumed only by local dedupe / sync-envelope logic; never log
   it, never send it in an MCP tool response, never include it in
   panic uploads.

## Common mistakes

- Adding a new worker and giving it its own retry loop instead of
  letting the supervisor observe failures. Supervision tree stops
  seeing the problem.
- Returning `Ok(())` from an MCP tool that hit a store error, so
  the client sees "no results" instead of a failure. Violates
  top-level rule 1.
- Bumping an MCP tool schema without an ADR — external clients
  break silently.

## Reference chain

- `../../BEST_PRACTICES.md` — MCI-wide invariants (root).
- `./README.md` — binary map and edit rules.
- `../../core/brain/BEST_PRACTICES.md` — refuse-to-serve rationale.
- `../../docs/decisions/0007-macos-capture-separate-signed-helper-process.md`,
  `0022-mcp-paid-tier-write-surface.md`,
  `0032-deep-hook-plugin-contract.md`.
