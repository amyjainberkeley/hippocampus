# core/mcp-client/

Pure-Rust JSON-RPC 2.0 client + stdio transport for V2-MCP outbound
aggregation. The MCP-client seat: MCI as an MCP *host* that talks to
external MCP servers (calendar, email, filesystem, etc.) and folds
their surfaces into the agent's tool set. See
`docs/research/v2-mcp-aggregation-scoping-2026-05-29.md`.

## Contents

- `src/` — crate root:
  - `client.rs` — the high-level `McpClient` handle.
  - `jsonrpc.rs` — JSON-RPC 2.0 request/response framing.
  - `stdio.rs`, `transport/` — stdio transport + trait for future
    HTTP/SSE transports.
  - `registry.rs` — declarative registration of external MCP servers.
  - `config.rs` — user-facing config schema.
  - `types.rs` — protocol type definitions.
  - `error.rs` — surfaces transport / protocol errors (never fall
    back — see `../../BEST_PRACTICES.md`).
- `tests/` — integration tests + an in-process echo fixture server.
- `Cargo.toml` — the `mci-mcp-client` package manifest.

## Related

- `../` — parent `mci-core` crate.
- `../../apps/agent/src/mcp/` — inbound MCP *server* surface (MCI
  exposes tools) and the aggregator that fans out to this client.
- `../../docs/decisions/0022-mcp-paid-tier-write-surface.md`.

## When to edit here

Outbound MCP wire changes, new transports, or protocol-version bumps.
Do NOT bake in a specific external server's quirks — those belong in
`config.rs` overrides or in `apps/agent/src/mcp/`. Adding a new tool
that MCI *exposes* is an agent-side change, not here.
