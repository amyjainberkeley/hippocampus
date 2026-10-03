-- 0012: one row per handoff packet delivered to a local agent client.
-- Content-free telemetry: the packet itself is never stored, only its
-- digest, size and the event ids it cited. Read by `mci-agent doctor`.
CREATE TABLE IF NOT EXISTS handoff_deliveries (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_us          INTEGER NOT NULL,
  client         TEXT NOT NULL,      -- claude-code | codex | cli | mcp
  project_root   TEXT NOT NULL,
  packet_sha256  TEXT NOT NULL,
  token_estimate INTEGER NOT NULL,
  event_ids      TEXT NOT NULL       -- JSON array of cited event ids
);
CREATE INDEX IF NOT EXISTS handoff_deliveries_ts ON handoff_deliveries(ts_us);
