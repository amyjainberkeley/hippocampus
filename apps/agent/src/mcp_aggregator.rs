//! V2-MCP-3 — MCP aggregator: pulls content from user-registered MCP
//! servers into the brain.
//!
//! # Where this module sits
//!
//! - **V2-MCP-1** (PR #245) shipped `core/mcp-client/`: the protocol
//!   layer + stdio transport + `ServerRegistry`.
//! - **V2-MCP-2** (PR #277) added the HTTP+SSE transport, the
//!   loopback-only ADR-0001 amendment, and the `mcp-servers.toml`
//!   loader. [`crate::mcp_client_supervisor::boot_default`] returns the
//!   shared `Arc<ServerRegistry>` populated from that file.
//! - **V2-MCP-3** (this module) consumes that registry. Per registered
//!   server it:
//!     1. Connects + handshakes (`initialize` +
//!        `notifications/initialized`).
//!     2. Catalogs `tools/list` in memory (V2-MCP-4 will surface the
//!        catalog for chat-driven invocation; this PR does NOT call
//!        any tool).
//!     3. Discovers `resources/list` and runs the
//!        **materialize-or-catalog** policy per resource:
//!         - SMALL (`<=` [`McpAggregator::materialize_max_bytes`] —
//!           512 KB default) → `resources/read` + persist as
//!           [`mci_brain::Event`].
//!         - LARGE (`>` cap) → persist a `[CATALOG_ONLY ...]` Event
//!           carrying URI + metadata only; V2-P12 (Phase 7 chat) does
//!           the at-query-time `resources/read` if the user asks.
//! - **V2-MCP-4** (Phase 7) reads the cataloged tools + catalog rows
//!   and surfaces them in the chat router.
//!
//! # Source-provenance tagging (CSO row 2 — load-bearing)
//!
//! Every Event the aggregator persists carries
//! `app_bundle_id = Some("mcp:<server-name>")`. The `mcp:` prefix is
//! the structural discriminator V2-P12 (Phase 7 chat surface) reads to
//! apply prompt-injection mitigation to MCP-sourced content per CRS
//! Fork-6 = A (ratified 2026-05-31; see
//! `docs/research/orchestrator-ratification-state-2026-05-31.md` §SH-6).
//!
//! We REUSE the existing `events.app_bundle_id` column rather than
//! adding a new `source` column because:
//!
//! 1. The deep-hook precedent already encodes source in
//!    `app_bundle_id`: `messages_ingest` writes
//!    `Some("com.apple.MobileSMS")` and `mail_ingest` writes
//!    `Some("com.apple.mail")` — both per-source identifiers that the
//!    redaction layer routes on (`bundle_is_in_scope` in
//!    `core/brain/src/redaction/mod.rs`). MCP source-provenance fits the
//!    same shape.
//! 2. Real Apple bundle ids follow reverse-DNS (`com.example.foo`) and
//!    NEVER start with `mcp:`. The prefix is an unambiguous namespace
//!    discriminator — V2-P12 can structurally filter via
//!    `app_bundle_id LIKE 'mcp:%'` without parser ambiguity.
//! 3. A new column would require forward-compat coordination with V2-P5
//!    (Tier2 NER), V2-P6 (AliasResolver), and the `episode_edges` chain
//!    — all of which are pending in cycle 8.30. Reusing the existing
//!    column lands V2-MCP-3 without a schema migration.
//!
//! # Fork F6 = A binding (CSO row 3) — NO cascade-equivalent at ingest
//!
//! Per CRS Fork-6 = A ratified 2026-05-31 + the ADR-0001 amendment in
//! PR #277 §"Operational rules" point 4: content returned by
//! user-registered MCP servers ingests AS-IS. There is NO
//! cascade-equivalent redaction at the V2-MCP-3 ingest boundary.
//! Trust model: the user installed and configured the server, so trust
//! ownership is on the user; downstream prompt-injection mitigation
//! happens at the V2-P12 chat surface using the source tag above.
//!
//! Note this is DIFFERENT from the deep-hook surfaces
//! ([`crate::messages_ingest`] / [`crate::mail_ingest`]): those ingest
//! Apple-app data the user did NOT explicitly opt-in to per-source,
//! and they DO run the §3(a)–(c) redaction layer at the source. The
//! `cascade_reason = 0` discriminator the
//! [`mci_brain::BrainStore::put_event`] guard enforces is preserved for
//! all MCP-sourced events — they ARE Allow-arm events, just with a
//! different trust boundary than OCR / browser / deep-hook frames.
//!
//! # Fork F7 = A binding (CSO row 1) — loopback-only transport
//!
//! The aggregator USES the `ServerRegistry`'s lazy `connect()` API,
//! which delegates to the V2-MCP-2 `HttpSseTransport` (for HTTP rows)
//! or `StdioTransport` (for stdio rows). The loopback gate is enforced
//! at registration time in `core/mcp-client/src/config.rs::register_all`
//! (every URL passes `LoopbackHost::parse`) AND at per-call connect via
//! the `LoopbackOnlyConnector` in
//! `core/mcp-client/src/transport/http_sse.rs`. This module does NOT
//! re-derive the gate and does NOT construct any HTTP client of its
//! own — every wire frame flows through the V2-MCP-2 transport.
//!
//! # Entity-graph integration (V2-P4 Tier 1)
//!
//! Materialized MCP events run through the same V2-P4 `Tier1Extractor`
//! that [`crate::brain_ingest::BrainPump`] invokes on its Allow-arm
//! after `put_event` returns. This is the load-bearing piece that
//! lets MCP-sourced events participate in the entity-graph the same
//! way OCR / browser / deep-hook events do — without it the
//! cross-app dot-connecting query the scoping memo §3.2 names
//! ("John was in this Slack thread AND this Safari tab") cannot
//! traverse MCP content. CATALOG_ONLY rows (large bodies) skip
//! Tier 1 — the marker text is metadata, not user content.
//!
//! # Tool execution scope (CSO row 4)
//!
//! V2-MCP-3 catalogs `tools/list` results in [`AggregatorState::tools`]
//! per server. It does NOT invoke any tool — no `tools/call` JSON-RPC
//! method is emitted by this module. Tool invocation is V2-MCP-4
//! (Phase 7 chat-router PR) when the user issues a chat query that the
//! router decides to route through an MCP tool.
//!
//! # Construction-graph wiring (CSO row 7)
//!
//! Per [[project-v2p1-unit-tests-passed-but-never-wired]]: the
//! aggregator is CONSTRUCTED at
//! `apps/agent/src/bin/mci_agent.rs::spawn_mcp_aggregator` immediately
//! after [`crate::mcp_client_supervisor::boot_default`] returns and the
//! brain store has been opened. The wiring test in
//! `apps/agent/tests/mcp_aggregator_wiring.rs` asserts construction
//! happens; `git log -S "McpAggregator::new" -- apps/agent/src/bin/mci_agent.rs`
//! returns this PR's commit per CSO row 7.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use mci_brain::extraction::{persist_tier1_matches, Tier1Extractor};
use mci_brain::{BrainStore, Embedder, Event, EventId};
use mci_mcp_client::{
    McpError, ResourceContent, ResourceDef, ServerRegistration, ServerRegistry, ToolDef,
};
use tokio::sync::{watch, Mutex};

use crate::brain_ingest::compose_context_header;

/// Default cadence for the reconcile loop. Mirrors the V2-P10
/// `PumpSupervisor::DEFAULT_RECONCILE_INTERVAL` discipline — a slow
/// outer beat that does not contend with the per-event hot paths.
/// 5 minutes per the V2-MCP-3 dispatch.
pub const DEFAULT_RECONCILE_INTERVAL: Duration = Duration::from_secs(5 * 60);

/// Default per-resource body cap. Resources whose `resources/read`
/// body exceeds this byte length are persisted as `[CATALOG_ONLY ...]`
/// Events (URI + metadata only) rather than materialized. The 512 KB
/// figure is the dispatch-pinned default; configurable in tests via
/// [`McpAggregator::with_max_bytes`].
///
/// Why 512 KB:
/// - A long Notion page renders at roughly 50–200 KB; the cap absorbs
///   the long tail.
/// - A single-file wiki article is typically `<` 100 KB.
/// - The footprint SLO (G2 raised — ≤10–15% CPU / ≤2 GB RAM on an
///   all-day session) allows hundreds of materialized resources per
///   day at this size without crowding the deep-hook ingest budget.
/// - A 100 MB Notion page (the dispatch's worst-case scenario) blows
///   the SLO and is rejected via the [`CATALOG_ONLY`](catalog_text)
///   path; the user explicitly opens it via V2-P12 to fetch.
pub const DEFAULT_MATERIALIZE_MAX_BYTES: usize = 512 * 1024;

/// Default cap on materialized resources per server per tick. Bounds
/// the burst when a server first comes online OR a new content batch
/// drops between two ticks. At 5-min cadence × 100 resources/tick ×
/// 512 KB/resource, the worst-case per-server ingest rate is
/// ~10 MB/min, well within the G2 SLO.
pub const DEFAULT_MAX_RESOURCES_PER_TICK: usize = 100;

/// Per-server timeout for a full reconcile pass (connect + handshake +
/// catalog + materialize). A stuck server cannot block the supervisor
/// past this — the next tick re-attempts.
pub const DEFAULT_PER_SERVER_TIMEOUT: Duration = Duration::from_secs(30);

/// `events.app_bundle_id` prefix for every MCP-sourced row. The
/// trailing `<server_name>` is the V2-MCP-2 registration name (already
/// constrained to `[a-zA-Z0-9_-]+` by `core/mcp-client/src/config.rs`,
/// so the resulting tag is `mcp:[a-zA-Z0-9_-]+` — unambiguous against
/// the reverse-DNS shape of real Apple bundle ids).
pub const MCP_SOURCE_PREFIX: &str = "mcp:";

/// Marker prepended to the `Event.text` of a CATALOG_ONLY row.
/// V2-P12 (Phase 7) pattern-matches this prefix to render a "fetch
/// the full content" affordance on the chat surface, then calls
/// `resources/read` live (which is OUT OF SCOPE here per the dispatch's
/// scope bind).
pub const CATALOG_ONLY_MARKER: &str = "[CATALOG_ONLY";

/// Cumulative stats for one [`McpAggregator`]. Every field is a
/// content-free counter (`u64`) — no MCP server URLs, no server tool
/// names, no event content. See ADR-0015 §4.6 + V2-MCP-2 audit row 6
/// for the discipline. Surfaced for tests + future telemetry hookup.
#[derive(Debug, Default)]
pub struct AggregatorStats {
    /// Number of reconcile ticks the supervisor has completed.
    pub ticks: AtomicU64,
    /// Successful per-server reconcile passes (initialize +
    /// catalog + materialize across all resources). Per-tick this can
    /// equal the registered count if every server is healthy.
    pub server_reconciles_ok: AtomicU64,
    /// Per-server reconcile failures. Surfaced so the
    /// telemetry-gap analyst can spot a regression where every tick is
    /// erroring out.
    pub server_reconciles_err: AtomicU64,
    /// Tools discovered + cataloged across all reconciles.
    pub tools_cataloged: AtomicU64,
    /// Resources discovered (sum across reconciles + servers).
    pub resources_discovered: AtomicU64,
    /// Resources materialized into the brain (text body `<=` cap).
    pub resources_materialized: AtomicU64,
    /// Resources persisted as `[CATALOG_ONLY ...]` rows
    /// (body `>` cap OR `resources/read` failed).
    pub resources_catalog_only: AtomicU64,
    /// `put_event` failures (BrainStore-side). Counter-only; the
    /// inner error is logged at the call site.
    pub put_event_errors: AtomicU64,
    /// V2-P4 Tier 1 entity mentions persisted from MCP-sourced
    /// events. Mirrors [`crate::brain_ingest::BrainPump`]'s
    /// `tier1_mentions_persisted` so the CRS Telemetry-Gap analyst
    /// can spot an entity-graph regression on either ingest path.
    pub tier1_mentions_persisted: AtomicU64,
}

impl AggregatorStats {
    /// Snapshot every counter into a plain struct for assertions.
    /// `Ordering::Relaxed` is enough — these counters are monotonic
    /// and have no synchronization relationship with anything else
    /// the agent does.
    #[must_use]
    pub fn snapshot(&self) -> AggregatorStatsSnapshot {
        AggregatorStatsSnapshot {
            ticks: self.ticks.load(Ordering::Relaxed),
            server_reconciles_ok: self.server_reconciles_ok.load(Ordering::Relaxed),
            server_reconciles_err: self.server_reconciles_err.load(Ordering::Relaxed),
            tools_cataloged: self.tools_cataloged.load(Ordering::Relaxed),
            resources_discovered: self.resources_discovered.load(Ordering::Relaxed),
            resources_materialized: self.resources_materialized.load(Ordering::Relaxed),
            resources_catalog_only: self.resources_catalog_only.load(Ordering::Relaxed),
            put_event_errors: self.put_event_errors.load(Ordering::Relaxed),
            tier1_mentions_persisted: self.tier1_mentions_persisted.load(Ordering::Relaxed),
        }
    }
}

/// Plain snapshot of [`AggregatorStats`]. Returned by
/// [`AggregatorStats::snapshot`] for cheap assertion against a frozen
/// reading.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(missing_docs)]
pub struct AggregatorStatsSnapshot {
    pub ticks: u64,
    pub server_reconciles_ok: u64,
    pub server_reconciles_err: u64,
    pub tools_cataloged: u64,
    pub resources_discovered: u64,
    pub resources_materialized: u64,
    pub resources_catalog_only: u64,
    pub put_event_errors: u64,
    pub tier1_mentions_persisted: u64,
}

/// Per-server mutable bookkeeping carried across ticks.
///
/// - `tools` is the in-memory snapshot of the last `tools/list` result
///   for this server. V2-MCP-4 (Phase 7) reads this to surface tools
///   in the chat router.
/// - `seen_resource_uris` is the dedupe set for materialized resources
///   across ticks within ONE agent lifetime. Cold-start posture
///   matches the V2-P10 `MessagesPluginPump`: a fresh process starts
///   with an empty set, so a server's CURRENT resource list is
///   materialized on the first tick. v2+ can persist this set to a
///   `mcp-cursors.toml` for restart-idempotent ingest.
#[derive(Debug, Default)]
struct ServerBookkeeping {
    tools: Vec<ToolDef>,
    seen_resource_uris: HashSet<String>,
}

/// Internal state, behind the `Mutex` so a snapshot-for-tests cannot
/// race with an in-flight reconcile.
#[derive(Default)]
struct AggregatorState {
    per_server: HashMap<String, ServerBookkeeping>,
}

/// V2-MCP-3 aggregator. Holds:
///
/// - `registry`: the V2-MCP-2 `Arc<ServerRegistry>` from
///   [`crate::mcp_client_supervisor::boot_default`]. The aggregator
///   consumes registrations — it does NOT mutate the registry (no
///   register / deregister calls). The user's onboarding flow owns
///   the registration lifecycle.
/// - `store`: the shared `Arc<dyn BrainStore>` that all the agent's
///   ingest paths write to. `cascade_reason = 0` events from this
///   aggregator land alongside OCR / browser / deep-hook events.
/// - `embedder`: `None` for v1; the idle-batch worker will fill
///   `event_vectors` for our zero-embedding inserts on its next pass.
///   The field is kept for symmetry with [`crate::brain_ingest::BrainPump`]
///   and for a future synchronous-embed mode (out of scope this PR).
/// - `stats`: content-free counters surfaced for tests + future
///   telemetry.
/// - `state`: per-server bookkeeping (tool catalog + seen-set).
pub struct McpAggregator {
    registry: Arc<ServerRegistry>,
    store: Arc<dyn BrainStore>,
    /// Held for symmetry with [`crate::brain_ingest::BrainPump`] and a
    /// future synchronous-embed mode. v1 inserts events with
    /// `embedding = None` so the idle-batch worker fills
    /// `event_vectors` on its next pass; the field is not yet read.
    #[allow(dead_code)]
    embedder: Option<Arc<dyn Embedder>>,
    materialize_max_bytes: usize,
    max_resources_per_tick: usize,
    reconcile_interval: Duration,
    per_server_timeout: Duration,
    stats: Arc<AggregatorStats>,
    state: Arc<Mutex<AggregatorState>>,
}

impl McpAggregator {
    /// Construct an aggregator with production defaults.
    ///
    /// `embedder` is held for symmetry with [`crate::brain_ingest::BrainPump`]
    /// but NOT exercised in v1 — events are inserted with
    /// `embedding = None` and the idle-batch worker fills
    /// `event_vectors` on its next pass.
    #[must_use]
    pub fn new(
        registry: Arc<ServerRegistry>,
        store: Arc<dyn BrainStore>,
        embedder: Option<Arc<dyn Embedder>>,
    ) -> Self {
        Self {
            registry,
            store,
            embedder,
            materialize_max_bytes: DEFAULT_MATERIALIZE_MAX_BYTES,
            max_resources_per_tick: DEFAULT_MAX_RESOURCES_PER_TICK,
            reconcile_interval: DEFAULT_RECONCILE_INTERVAL,
            per_server_timeout: DEFAULT_PER_SERVER_TIMEOUT,
            stats: Arc::new(AggregatorStats::default()),
            state: Arc::new(Mutex::new(AggregatorState::default())),
        }
    }

    /// Test-knob: override the materialize-vs-catalog body cap.
    /// Production code uses [`Self::new`] (which pins the dispatch's
    /// 512 KB default).
    #[must_use]
    pub fn with_max_bytes(mut self, max_bytes: usize) -> Self {
        self.materialize_max_bytes = max_bytes;
        self
    }

    /// Test-knob: override the per-tick resource cap.
    #[must_use]
    pub fn with_max_resources_per_tick(mut self, n: usize) -> Self {
        self.max_resources_per_tick = n;
        self
    }

    /// Test-knob: override the reconcile interval.
    #[must_use]
    pub fn with_reconcile_interval(mut self, d: Duration) -> Self {
        self.reconcile_interval = d;
        self
    }

    /// Test-knob: override the per-server timeout.
    #[must_use]
    pub fn with_per_server_timeout(mut self, d: Duration) -> Self {
        self.per_server_timeout = d;
        self
    }

    /// Reach into the shared stats counter.
    #[must_use]
    pub fn stats(&self) -> Arc<AggregatorStats> {
        Arc::clone(&self.stats)
    }

    /// Snapshot the per-server tool catalog. V2-MCP-4 (Phase 7) will
    /// consume this to surface tools in the chat router. The returned
    /// map is a clone (cheap — ToolDefs are small) so callers do not
    /// hold the aggregator's lock.
    pub async fn tool_catalog(&self) -> HashMap<String, Vec<ToolDef>> {
        let state = self.state.lock().await;
        state
            .per_server
            .iter()
            .map(|(k, v)| (k.clone(), v.tools.clone()))
            .collect()
    }

    /// Run the reconcile loop until `shutdown` flips to `true`.
    ///
    /// The loop:
    /// 1. Performs one [`Self::reconcile_once`] pass.
    /// 2. Sleeps `reconcile_interval`, or returns early on shutdown.
    ///
    /// The shutdown path NEVER blocks on a live `resources/read` —
    /// the per-server timeout caps each pass, and `tokio::select!`
    /// races the sleep against the shutdown signal so a flag-flip is
    /// observed within `per_server_timeout` at worst.
    pub async fn run(self, mut shutdown: watch::Receiver<bool>) {
        loop {
            // Check shutdown BEFORE work — a flag flipped between two
            // ticks should not earn one more tick of work.
            if *shutdown.borrow() {
                break;
            }
            self.reconcile_once().await;
            self.stats.ticks.fetch_add(1, Ordering::Relaxed);

            // Race the sleep against shutdown so a SIGINT lands quickly.
            tokio::select! {
                _ = tokio::time::sleep(self.reconcile_interval) => {},
                _ = shutdown.changed() => {
                    if *shutdown.borrow() {
                        break;
                    }
                }
            }
        }
    }

    /// One reconcile tick: walk every registered server, do its pass.
    /// Public for test wiring; production callers use [`Self::run`].
    pub async fn reconcile_once(&self) {
        let registrations = self.registry.list().await;
        for registration in registrations {
            let server_name = registration.name.clone();
            let outcome = tokio::time::timeout(
                self.per_server_timeout,
                self.reconcile_server(&registration),
            )
            .await;
            match outcome {
                Ok(Ok(())) => {
                    self.stats.server_reconciles_ok.fetch_add(1, Ordering::Relaxed);
                }
                Ok(Err(e)) => {
                    self.stats
                        .server_reconciles_err
                        .fetch_add(1, Ordering::Relaxed);
                    // §5.4 content-free discipline — the server `name`
                    // alone reaches stderr. Never the URL, never the
                    // auth header, never the error body.
                    tracing::warn!(
                        target: "mci_agent::mcp_aggregator",
                        server = %server_name,
                        kind = %registration.transport_kind(),
                        "reconcile failed: {}",
                        sanitized_err(&e),
                    );
                }
                Err(_timeout) => {
                    self.stats
                        .server_reconciles_err
                        .fetch_add(1, Ordering::Relaxed);
                    tracing::warn!(
                        target: "mci_agent::mcp_aggregator",
                        server = %server_name,
                        kind = %registration.transport_kind(),
                        timeout_secs = self.per_server_timeout.as_secs(),
                        "reconcile timed out",
                    );
                }
            }
        }
    }

    /// One server's reconcile: connect, handshake, catalog tools,
    /// discover + materialize resources within the per-tick budget.
    async fn reconcile_server(
        &self,
        registration: &ServerRegistration,
    ) -> Result<(), McpError> {
        let server_name = &registration.name;
        let client = self.registry.connect(server_name).await?;
        let _init = client.initialize().await?;

        // Tools catalog — discover + stash in-memory. NO `tools/call`
        // is emitted (CSO row 4).
        let tools = match client.tools_list().await {
            Ok(t) => t,
            Err(McpError::Rpc(_)) | Err(McpError::SchemaMismatch(_)) => Vec::new(),
            Err(e) => return Err(e),
        };
        let tool_count = tools.len();
        self.stats
            .tools_cataloged
            .fetch_add(tool_count as u64, Ordering::Relaxed);

        // Resources discovery — `resources/list` returns the resource
        // CATALOG; per-resource `resources/read` follows the materialize-
        // or-catalog policy below.
        let resources = match client.resources_list().await {
            Ok(r) => r,
            Err(McpError::Rpc(_)) | Err(McpError::SchemaMismatch(_)) => Vec::new(),
            Err(e) => return Err(e),
        };
        self.stats
            .resources_discovered
            .fetch_add(resources.len() as u64, Ordering::Relaxed);

        // Snapshot the prior seen-set (cheap clone — URIs are short)
        // so we don't hold the state lock across `resources/read`
        // network calls.
        let prior_seen: HashSet<String> = {
            let state = self.state.lock().await;
            state
                .per_server
                .get(server_name)
                .map(|bk| bk.seen_resource_uris.clone())
                .unwrap_or_default()
        };

        let mut tick_materialized = 0usize;
        let mut newly_seen: Vec<String> = Vec::new();

        for resource in &resources {
            if tick_materialized >= self.max_resources_per_tick {
                break;
            }
            if prior_seen.contains(&resource.uri) {
                continue;
            }
            // Mark seen BEFORE we read so a transient read failure
            // doesn't cause re-attempts on every tick — the v1 policy
            // is "best-effort, one shot per agent lifetime per URI".
            // Restart re-tries (no across-restart persistence in v1).
            newly_seen.push(resource.uri.clone());

            let ts_us = now_us();
            let read_outcome = client.resources_read(&resource.uri).await;
            match read_outcome {
                Ok(read_result) => {
                    let body = concat_text(&read_result.contents);
                    if body.len() <= self.materialize_max_bytes {
                        let event = self.materialize_event(
                            server_name,
                            resource,
                            &body,
                            ts_us,
                        );
                        match self.store.put_event(&event) {
                            Ok(id) => {
                                self.stats
                                    .resources_materialized
                                    .fetch_add(1, Ordering::Relaxed);
                                // V2-P4 Tier 1 entity extraction —
                                // mirror the
                                // `BrainPump::ingest_ocr_event` Allow-
                                // arm path so MCP-sourced events
                                // participate in the entity-graph the
                                // same way OCR / browser events do.
                                // Per the scoping memo §3.2 this is
                                // the load-bearing piece that makes
                                // the "John was in this Slack thread
                                // AND this Safari tab" cross-app
                                // dot-connecting query work.
                                //
                                // Best-effort per the brain_ingest
                                // discipline (line 487): a Tier 1
                                // persistence failure does NOT roll
                                // back the event row — the event
                                // lives; mentions can be backfilled
                                // later because every Tier 1 writer
                                // is idempotent on PK by construction.
                                self.run_tier1_extraction(
                                    server_name,
                                    id,
                                    &event,
                                );
                            }
                            Err(e) => {
                                self.stats
                                    .put_event_errors
                                    .fetch_add(1, Ordering::Relaxed);
                                tracing::warn!(
                                    target: "mci_agent::mcp_aggregator",
                                    server = %server_name,
                                    "put_event failed for materialize: {e}",
                                );
                            }
                        }
                    } else {
                        let event = self.catalog_only_event(
                            server_name,
                            resource,
                            Some(body.len()),
                            ts_us,
                        );
                        self.persist_catalog_event(server_name, &event);
                    }
                    tick_materialized += 1;
                }
                Err(_) => {
                    // `resources/read` failed — persist a CATALOG_ONLY
                    // row anyway so V2-P12 can still surface the
                    // resource. No body; size unknown.
                    let event = self.catalog_only_event(server_name, resource, None, ts_us);
                    self.persist_catalog_event(server_name, &event);
                    tick_materialized += 1;
                }
            }
        }

        // Commit: stash the updated tool catalog + seen-set under one
        // lock. Holding the lock here is fine — the per-server async
        // network calls already returned.
        let mut state = self.state.lock().await;
        let bk = state
            .per_server
            .entry(server_name.clone())
            .or_default();
        bk.tools = tools;
        bk.seen_resource_uris.extend(newly_seen);

        Ok(())
    }

    /// V2-P4 Tier 1 extraction over a materialized MCP event.
    /// Cataloged-only rows skip this path — the [`CATALOG_ONLY_MARKER`]
    /// body is metadata, not user content, so there is no entity
    /// surface to extract from.
    fn run_tier1_extraction(&self, server_name: &str, event_id: EventId, event: &Event) {
        let extractor = Tier1Extractor::new();
        let matches = extractor.extract(&event.text);
        if matches.is_empty() {
            return;
        }
        match persist_tier1_matches(&*self.store, event_id, event.ts_us, &matches) {
            Ok(stats) => {
                self.stats
                    .tier1_mentions_persisted
                    .fetch_add(stats.mentions_inserted as u64, Ordering::Relaxed);
            }
            Err(e) => {
                tracing::warn!(
                    target: "mci_agent::mcp_aggregator",
                    server = %server_name,
                    "tier1 persist failed for event {event_id:?}: {e}",
                );
            }
        }
    }

    /// Persist a `[CATALOG_ONLY ...]` event + bump the right counter.
    /// Encapsulated so both the "body too large" and "read errored"
    /// branches share the same code path.
    fn persist_catalog_event(&self, server_name: &str, event: &Event) {
        match self.store.put_event(event) {
            Ok(_id) => {
                self.stats
                    .resources_catalog_only
                    .fetch_add(1, Ordering::Relaxed);
            }
            Err(e) => {
                self.stats
                    .put_event_errors
                    .fetch_add(1, Ordering::Relaxed);
                tracing::warn!(
                    target: "mci_agent::mcp_aggregator",
                    server = %server_name,
                    "put_event failed for catalog: {e}",
                );
            }
        }
    }

    /// Construct an Event for a materialized MCP resource. The
    /// `app_bundle_id` carries the load-bearing `mcp:<server>` source
    /// tag (CSO row 2); `text` carries the ADR-0010 §1.3 context
    /// header + the resource body so FTS5 indexes the same content the
    /// embedder (when run) sees. `cascade_reason = 0` per
    /// `BrainStore::put_event`'s belt-and-suspenders check (the events
    /// ARE Allow-arm even though no cascade ran — Fork F6 = A).
    fn materialize_event(
        &self,
        server_name: &str,
        resource: &ResourceDef,
        body: &str,
        ts_us: u64,
    ) -> Event {
        let app = source_tag(server_name);
        let title = resource_title(resource);
        let url = Some(resource.uri.clone());
        let header = compose_context_header(Some(&app), title.as_deref(), url.as_deref(), ts_us);
        let mut text = String::with_capacity(header.len() + body.len());
        text.push_str(&header);
        text.push_str(body);
        Event {
            id: EventId(0),
            ts_us,
            app_bundle_id: Some(app),
            window_title: title,
            url,
            text,
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding: None,
        }
    }

    /// Construct a CATALOG_ONLY Event — no body bytes, only the URI +
    /// metadata. V2-P12 (Phase 7) pattern-matches the
    /// [`CATALOG_ONLY_MARKER`] prefix to render a "fetch the full
    /// content" affordance + call `resources/read` live on user click.
    fn catalog_only_event(
        &self,
        server_name: &str,
        resource: &ResourceDef,
        approx_size: Option<usize>,
        ts_us: u64,
    ) -> Event {
        let app = source_tag(server_name);
        let title = resource_title(resource);
        let url = Some(resource.uri.clone());
        let header = compose_context_header(Some(&app), title.as_deref(), url.as_deref(), ts_us);
        let mut text = String::with_capacity(header.len() + 128);
        text.push_str(&header);
        text.push_str(&catalog_text(resource, approx_size));
        Event {
            id: EventId(0),
            ts_us,
            app_bundle_id: Some(app),
            window_title: title,
            url,
            text,
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding: None,
        }
    }
}

/// `mcp:<server-name>` — the source tag. Pulled into a free function
/// so tests can assert the discriminator shape without owning the
/// aggregator.
#[must_use]
pub fn source_tag(server_name: &str) -> String {
    format!("{MCP_SOURCE_PREFIX}{server_name}")
}

/// True iff `app_bundle_id` is an MCP source tag. V2-P12 (Phase 7) is
/// the structural consumer; exposed here so tests + future hooks can
/// share the discriminator logic.
#[must_use]
pub fn is_mcp_source(app_bundle_id: &str) -> bool {
    app_bundle_id.starts_with(MCP_SOURCE_PREFIX)
}

/// Body of a CATALOG_ONLY event. Stable shape so V2-P12 can parse it
/// reliably. Format:
///
/// ```text
/// [CATALOG_ONLY uri=<u> name=<n> mime=<m> bytes=<b_or_unknown>]
/// ```
fn catalog_text(resource: &ResourceDef, approx_size: Option<usize>) -> String {
    let name = resource.name.as_deref().unwrap_or("?");
    let mime = resource.mime_type.as_deref().unwrap_or("?");
    let bytes = approx_size.map_or_else(|| "unknown".to_owned(), |n| n.to_string());
    format!(
        "{CATALOG_ONLY_MARKER} uri={} name={name} mime={mime} bytes={bytes}]",
        resource.uri
    )
}

/// Pull the resource's `name`/`description` as the event's
/// `window_title` so the recall surface has something human-readable
/// to render. Falls back to `None` if both are absent.
fn resource_title(resource: &ResourceDef) -> Option<String> {
    resource
        .name
        .clone()
        .or_else(|| resource.description.clone())
}

/// Concatenate the text payloads of a `resources/read` result into
/// one string. Skips blob entries (binary content; v1 has no
/// consumer for it).
fn concat_text(contents: &[ResourceContent]) -> String {
    let mut out = String::new();
    for c in contents {
        if let Some(t) = &c.text {
            if !out.is_empty() {
                out.push('\n');
            }
            out.push_str(t);
        }
    }
    out
}

/// Map an `McpError` to a content-free log string. The variant name is
/// surfaced; the inner payload (which may carry a URL or auth-derived
/// message) is NOT logged. Mirrors the V2-MCP-2 audit row 7 discipline.
fn sanitized_err(err: &McpError) -> &'static str {
    match err {
        McpError::Io(_) => "io",
        McpError::Rpc(_) => "rpc",
        McpError::MalformedFrame { .. } => "malformed_frame",
        McpError::Timeout { .. } => "timeout",
        McpError::SchemaMismatch(_) => "schema_mismatch",
        McpError::Closed => "closed",
        McpError::Serialize(_) => "serialize",
    }
}

/// Wall-clock now in microseconds. The aggregator does NOT need the
/// `WallClock` injection that the deep-hook pumps use because the
/// per-resource ts is purely "when did we materialize this", not a
/// content-attribution timestamp.
fn now_us() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_micros()).unwrap_or(u64::MAX))
}

#[cfg(test)]
mod tests {
    use super::*;
    use mci_brain::stubs::InMemoryBrainStore;
    use mci_mcp_client::{ServerRegistration, ServerRegistry};

    fn aggregator_with_empty_registry() -> (Arc<ServerRegistry>, Arc<InMemoryBrainStore>, McpAggregator) {
        let registry = Arc::new(ServerRegistry::new());
        let store = Arc::new(InMemoryBrainStore::new());
        let agg = McpAggregator::new(
            Arc::clone(&registry),
            Arc::clone(&store) as Arc<dyn BrainStore>,
            None,
        );
        (registry, store, agg)
    }

    fn make_resource(uri: &str, name: &str, mime: &str) -> ResourceDef {
        // Constructed via JSON because ResourceDef has only Deserialize
        // — keeps the test independent of any private constructor.
        serde_json::from_value(serde_json::json!({
            "uri": uri,
            "name": name,
            "mimeType": mime,
        }))
        .expect("ResourceDef parse")
    }

    fn make_resource_minimal(uri: &str) -> ResourceDef {
        serde_json::from_value(serde_json::json!({ "uri": uri })).expect("ResourceDef parse")
    }

    #[test]
    fn source_tag_carries_prefix() {
        assert_eq!(source_tag("gchat"), "mcp:gchat");
        assert_eq!(source_tag("slack-personal"), "mcp:slack-personal");
        assert!(is_mcp_source("mcp:gchat"));
        assert!(is_mcp_source("mcp:slack-personal"));
        assert!(!is_mcp_source("com.apple.MobileSMS"));
        assert!(!is_mcp_source("com.apple.mail"));
        assert!(!is_mcp_source("com.google.Chrome"));
    }

    #[test]
    fn source_tag_never_collides_with_reverse_dns_bundle_id() {
        // Real Apple bundle ids are reverse-DNS; they never start
        // with `mcp:`. This invariant is what makes the namespace
        // discriminator safe (see module doc).
        for real_bundle in [
            "com.apple.MobileSMS",
            "com.apple.mail",
            "com.google.Chrome",
            "com.apple.Safari",
            "company.thebrowser.Browser",
            "org.mozilla.firefox",
        ] {
            assert!(
                !real_bundle.starts_with(MCP_SOURCE_PREFIX),
                "real bundle id {real_bundle} collides with MCP source prefix"
            );
        }
    }

    #[test]
    fn materialize_event_carries_source_tag_and_zero_cascade_reason() {
        let (_reg, _store, agg) = aggregator_with_empty_registry();
        let resource = make_resource("slack://channels/C123", "design-review", "text/plain");
        let event = agg.materialize_event("slack", &resource, "hello world", 1_700_000_000_000_000);
        assert_eq!(event.app_bundle_id.as_deref(), Some("mcp:slack"));
        assert_eq!(event.cascade_reason, 0);
        assert!(event.text.contains("hello world"));
        assert!(event.text.starts_with("[app=mcp:slack"));
        assert_eq!(event.url.as_deref(), Some("slack://channels/C123"));
        assert_eq!(event.window_title.as_deref(), Some("design-review"));
        assert!(event.embedding.is_none(), "embedder is None in v1");
        assert!(event.keyframe_blob.is_none());
        assert!(event.tab_id.is_none());
    }

    #[test]
    fn catalog_event_carries_marker_and_source_tag() {
        let (_reg, _store, agg) = aggregator_with_empty_registry();
        let resource = make_resource("notion://page/abc", "Q4 Plan", "text/html");
        let event = agg.catalog_only_event("notion", &resource, Some(1_500_000), 1_700_000_000_000_000);
        assert_eq!(event.app_bundle_id.as_deref(), Some("mcp:notion"));
        assert_eq!(event.cascade_reason, 0);
        assert!(event.text.contains(CATALOG_ONLY_MARKER));
        assert!(event.text.contains("notion://page/abc"));
        assert!(event.text.contains("bytes=1500000"));
        assert!(event.text.contains("name=Q4 Plan"));
        assert!(event.text.contains("mime=text/html"));
    }

    #[test]
    fn catalog_event_with_unknown_size() {
        let (_reg, _store, agg) = aggregator_with_empty_registry();
        let resource = make_resource_minimal("linear://issue/MCI-1");
        let event = agg.catalog_only_event("linear", &resource, None, 1_700_000_000_000_000);
        assert_eq!(event.app_bundle_id.as_deref(), Some("mcp:linear"));
        assert!(event.text.contains("bytes=unknown"));
        // Defaults — both unset.
        assert!(event.text.contains("name=?"));
        assert!(event.text.contains("mime=?"));
    }

    #[test]
    fn catalog_text_uses_stable_marker_for_v2p12_parsing() {
        // V2-P12 (Phase 7) pattern-matches CATALOG_ONLY_MARKER. The
        // marker is part of the structural API surface between
        // V2-MCP-3 and V2-P12; assert it doesn't drift.
        assert_eq!(CATALOG_ONLY_MARKER, "[CATALOG_ONLY");
        let resource = make_resource_minimal("any://thing");
        let body = catalog_text(&resource, Some(42));
        assert!(body.starts_with(CATALOG_ONLY_MARKER));
        assert!(body.ends_with(']'));
    }

    #[test]
    fn concat_text_skips_blob_entries_and_joins_text() {
        let contents = vec![
            serde_json::from_value::<ResourceContent>(serde_json::json!({
                "uri": "x", "text": "hello", "mimeType": "text/plain"
            }))
            .unwrap(),
            serde_json::from_value::<ResourceContent>(serde_json::json!({
                "uri": "y", "blob": "aGVsbG8=", "mimeType": "image/png"
            }))
            .unwrap(),
            serde_json::from_value::<ResourceContent>(serde_json::json!({
                "uri": "z", "text": "world", "mimeType": "text/plain"
            }))
            .unwrap(),
        ];
        let joined = concat_text(&contents);
        assert_eq!(joined, "hello\nworld");
    }

    #[test]
    fn sanitized_err_returns_only_variant_names() {
        // Audit row 7 / row 8 — no error payload bytes reach logs.
        // We assert the sanitizer is exhaustive over the McpError
        // variants by exercising every constructable shape.
        assert_eq!(
            sanitized_err(&McpError::SchemaMismatch("payload that must not leak".into())),
            "schema_mismatch",
        );
        assert_eq!(sanitized_err(&McpError::Closed), "closed");
        assert_eq!(
            sanitized_err(&McpError::Timeout {
                timeout_ms: 100,
                method: "tools/list".into()
            }),
            "timeout"
        );
        assert_eq!(
            sanitized_err(&McpError::MalformedFrame {
                reason: "payload that must not leak".into()
            }),
            "malformed_frame",
        );
    }

    #[tokio::test]
    async fn reconcile_once_with_empty_registry_does_nothing() {
        let (_registry, _store, agg) = aggregator_with_empty_registry();
        agg.reconcile_once().await;
        let snap = agg.stats.snapshot();
        assert_eq!(snap.server_reconciles_ok, 0);
        assert_eq!(snap.server_reconciles_err, 0);
        assert_eq!(snap.resources_materialized, 0);
        assert_eq!(snap.resources_catalog_only, 0);
    }

    #[tokio::test]
    async fn run_loop_exits_promptly_on_shutdown() {
        // Confirms tokio::select! against shutdown wins fast.
        let (_registry, _store, agg) = aggregator_with_empty_registry();
        let agg = agg
            .with_reconcile_interval(Duration::from_secs(3600))
            .with_per_server_timeout(Duration::from_millis(100));
        let (tx, rx) = watch::channel(false);
        let handle = tokio::spawn(async move {
            agg.run(rx).await;
        });
        // Let one tick happen.
        tokio::time::sleep(Duration::from_millis(50)).await;
        tx.send(true).expect("shutdown send");
        let join =
            tokio::time::timeout(Duration::from_millis(500), handle).await;
        assert!(join.is_ok(), "aggregator should exit within 500ms of shutdown");
    }

    #[tokio::test]
    async fn run_loop_observes_initial_shutdown_without_a_tick() {
        // If shutdown is true before run starts, no tick should fire.
        let (_registry, _store, agg) = aggregator_with_empty_registry();
        let stats = agg.stats();
        let (tx, rx) = watch::channel(false);
        tx.send(true).expect("send true");
        let handle = tokio::spawn(async move {
            agg.run(rx).await;
        });
        tokio::time::timeout(Duration::from_millis(200), handle)
            .await
            .expect("exit")
            .expect("join");
        assert_eq!(stats.snapshot().ticks, 0);
    }

    #[tokio::test]
    async fn registered_server_with_unreachable_stdio_counts_as_err_not_panic() {
        // Reconcile against a registered server whose `command` does
        // not exist. The connect fails, the per-server pass returns
        // Err, the supervisor counts it and continues.
        let registry = Arc::new(ServerRegistry::new());
        let _h = registry
            .register(ServerRegistration::stdio(
                "ghost",
                "/path/to/nothing/here",
                Vec::<String>::new(),
            ))
            .await;
        let store = Arc::new(InMemoryBrainStore::new());
        let agg = McpAggregator::new(
            Arc::clone(&registry),
            Arc::clone(&store) as Arc<dyn BrainStore>,
            None,
        )
        .with_per_server_timeout(Duration::from_millis(500));
        agg.reconcile_once().await;
        let snap = agg.stats.snapshot();
        assert_eq!(snap.server_reconciles_ok, 0);
        assert_eq!(snap.server_reconciles_err, 1);
        assert_eq!(snap.resources_materialized, 0);
        assert_eq!(snap.resources_catalog_only, 0);
    }
}
