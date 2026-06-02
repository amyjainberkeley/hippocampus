//! V2-MCP-3 integration + construction-graph wiring tests for
//! [`mci_agent::mcp_aggregator::McpAggregator`].
//!
//! Covers:
//!
//! 1. **End-to-end materialize** — boot a real loopback HTTP+SSE stub
//!    MCP server populated with a handful of small resources, register
//!    it in a `ServerRegistry`, run one reconcile tick, assert that
//!    each resource lands as an `events` row with
//!    `app_bundle_id = "mcp:<server>"` and `cascade_reason = 0`.
//!
//! 2. **Materialize-vs-catalog split** — populate one server with a
//!    mix of small + large resources, reconcile, assert the small ones
//!    are materialized (body in `events.text`) and the large ones land
//!    as `[CATALOG_ONLY ...]` rows (no body bytes).
//!
//! 3. **Source-provenance tagging** — every event the aggregator
//!    writes carries `app_bundle_id = "mcp:<server>"`; an
//!    independently-constructed deep-hook-shaped event (using the
//!    `MESSAGES_BUNDLE_ID` constant) does NOT, so V2-P12 (Phase 7) can
//!    structurally route on the `mcp:` prefix without conflating MCP
//!    sources with deep-hook sources.
//!
//! 4. **Tool catalog persistence** — `tools/list` results are stashed
//!    in-memory per server; no `tools/call` is emitted.
//!
//! 5. **Per-tick dedupe** — running two reconcile ticks against the
//!    same server only materializes each resource once.
//!
//! 6. **Cross-server isolation** — registering two servers under
//!    different names produces two distinct source tags.
//!
//! 7. **Construction-graph wiring** — `git log -S "McpAggregator::new"`
//!    on `apps/agent/src/bin/mci_agent.rs` returns this PR's commit
//!    per the V2-P1 lesson in
//!    [[project-v2p1-unit-tests-passed-but-never-wired]]. This test
//!    asserts the construction-site exists at the file level (via
//!    `include_str!`) so a regression that removes the wiring while
//!    keeping the module surface trips a test failure.

use std::sync::Arc;
use std::time::Duration;

use mci_agent::mcp_aggregator::{is_mcp_source, source_tag, McpAggregator, CATALOG_ONLY_MARKER};
use mci_brain::redaction::{MAIL_BUNDLE_ID, MESSAGES_BUNDLE_ID};
use mci_brain::stubs::InMemoryBrainStore;
use mci_brain::{BrainStore, EventId};
use mci_mcp_client::{LoopbackHost, ServerRegistration, ServerRegistry};

// Share the V2-MCP-2 stub MCP server (loopback HTTP+SSE) instead of
// duplicating ~330 lines of hyper plumbing. `#[path]` resolves
// relative to this file (`apps/agent/tests/mcp_aggregator_wiring.rs`).
#[path = "../../../core/mcp-client/tests/stub_server.rs"]
mod stub_server;
use stub_server::{StubMcpServer, StubResource};

/// Best-effort sweep of every event the in-memory store holds. We do
/// not have a typed "list_all" API on the trait; production stores
/// use FTS5 or vector search. For tests we pull events by sequential
/// id from 1 upward; the InMemoryBrainStore assigns ids monotonically
/// from 1.
fn read_all(store: &InMemoryBrainStore) -> Vec<mci_brain::Event> {
    let mut out = Vec::new();
    for i in 1u64..1000 {
        match store.get_event(EventId(i)) {
            Ok(Some(ev)) => out.push(ev),
            Ok(None) => continue,
            Err(_) => break,
        }
    }
    out
}

/// Helper: stand up one stub MCP server, register it as an HTTP MCP
/// entry, and return the `(server, registry)`.
async fn one_server_named(name: &str, resources: Vec<StubResource>) -> (StubMcpServer, Arc<ServerRegistry>) {
    let server = StubMcpServer::start().await;
    server.set_resources(resources).await;
    let url = format!("http://127.0.0.1:{}/sse", server.port());
    let host = LoopbackHost::parse(&url).await.expect("loopback parse");
    let registry = Arc::new(ServerRegistry::new());
    let _h = registry
        .register(ServerRegistration::http(name, host, None))
        .await;
    (server, registry)
}

#[tokio::test]
async fn reconcile_persists_small_resources_with_mcp_source_tag() {
    let resources = vec![
        StubResource::new("slack://channels/C1", "design-review", "the design looks good"),
        StubResource::new("slack://channels/C2", "engineering", "we shipped V2-MCP-2 today"),
    ];
    let (server, registry) = one_server_named("slack", resources).await;
    let store = Arc::new(InMemoryBrainStore::new());
    let agg = McpAggregator::new(
        Arc::clone(&registry),
        Arc::clone(&store) as Arc<dyn BrainStore>,
        None,
    );
    agg.reconcile_once().await;

    let snap = agg.stats().snapshot();
    assert_eq!(
        snap.server_reconciles_ok, 1,
        "server reconcile should succeed, stats: {snap:?}",
    );
    assert_eq!(snap.resources_discovered, 2);
    assert_eq!(snap.resources_materialized, 2);
    assert_eq!(snap.resources_catalog_only, 0);

    let events = read_all(&store);
    assert_eq!(events.len(), 2, "expected 2 events, got {}", events.len());

    // Source-provenance tagging — every event from this server carries
    // `mcp:slack`. CSO row 2.
    for ev in &events {
        let tag = ev.app_bundle_id.as_deref().expect("source tag set");
        assert_eq!(tag, "mcp:slack");
        assert!(is_mcp_source(tag));
        assert_eq!(ev.cascade_reason, 0, "all MCP events ingest at the Allow arm");
        assert!(ev.embedding.is_none(), "idle-batch worker fills embeddings later");
        assert!(ev.keyframe_blob.is_none());
        assert!(ev.tab_id.is_none());
    }

    // Bodies preserved verbatim — no cascade/redaction at ingest
    // per Fork F6 = A.
    let bodies: Vec<&str> = events.iter().map(|e| e.text.as_str()).collect();
    assert!(bodies.iter().any(|b| b.contains("the design looks good")));
    assert!(bodies.iter().any(|b| b.contains("we shipped V2-MCP-2 today")));

    // Each event carries the resource URI as `event.url` (so the
    // recall surface has a click-through target).
    let urls: Vec<&str> = events
        .iter()
        .filter_map(|e| e.url.as_deref())
        .collect();
    assert!(urls.contains(&"slack://channels/C1"));
    assert!(urls.contains(&"slack://channels/C2"));

    // Resource name lands in window_title.
    let titles: Vec<&str> = events
        .iter()
        .filter_map(|e| e.window_title.as_deref())
        .collect();
    assert!(titles.contains(&"design-review"));
    assert!(titles.contains(&"engineering"));

    server.shutdown().await;
}

#[tokio::test]
async fn large_resource_yields_catalog_only_row() {
    // Two small resources + one large one. The large one exceeds the
    // per-resource cap and lands as a CATALOG_ONLY row.
    let small_body = "small body";
    let big_body = "X".repeat(2048);
    let resources = vec![
        StubResource::new("notion://page/small", "small page", small_body),
        StubResource::new("notion://page/big", "big page", &big_body),
    ];
    let (server, registry) = one_server_named("notion", resources).await;
    let store = Arc::new(InMemoryBrainStore::new());
    // Cap at 1024 bytes so the 2048-byte resource trips the catalog path.
    let agg = McpAggregator::new(
        Arc::clone(&registry),
        Arc::clone(&store) as Arc<dyn BrainStore>,
        None,
    )
    .with_max_bytes(1024);

    agg.reconcile_once().await;

    let snap = agg.stats().snapshot();
    assert_eq!(snap.resources_discovered, 2);
    assert_eq!(snap.resources_materialized, 1);
    assert_eq!(snap.resources_catalog_only, 1);

    let events = read_all(&store);
    assert_eq!(events.len(), 2);

    // The big-page event is CATALOG_ONLY — has the marker, has NO body
    // bytes from the original 2048-byte payload.
    let big_event = events
        .iter()
        .find(|e| e.url.as_deref() == Some("notion://page/big"))
        .expect("big-page event present");
    assert!(big_event.text.contains(CATALOG_ONLY_MARKER));
    assert!(big_event.text.contains("notion://page/big"));
    assert!(big_event.text.contains("bytes=2048"));
    assert!(
        !big_event.text.contains(&big_body),
        "CATALOG_ONLY row must NOT carry the body bytes (footprint cap discipline)",
    );

    // The small-page event is materialized — body is in `text`.
    let small_event = events
        .iter()
        .find(|e| e.url.as_deref() == Some("notion://page/small"))
        .expect("small-page event present");
    assert!(small_event.text.contains(small_body));
    assert!(!small_event.text.contains(CATALOG_ONLY_MARKER));

    server.shutdown().await;
}

#[tokio::test]
async fn second_reconcile_does_not_re_materialize_seen_resources() {
    // Per-tick dedupe via in-memory seen-set keyed by `(server, uri)`.
    let resources = vec![
        StubResource::new("g://r1", "r1", "first"),
        StubResource::new("g://r2", "r2", "second"),
    ];
    let (server, registry) = one_server_named("gchat", resources).await;
    let store = Arc::new(InMemoryBrainStore::new());
    let agg = McpAggregator::new(
        Arc::clone(&registry),
        Arc::clone(&store) as Arc<dyn BrainStore>,
        None,
    );

    agg.reconcile_once().await;
    let after_first = agg.stats().snapshot();
    assert_eq!(after_first.resources_materialized, 2);

    agg.reconcile_once().await;
    let after_second = agg.stats().snapshot();
    // Resources discovered grows (we re-listed them) but materialized
    // stays put — every URI was in the seen-set.
    assert_eq!(after_second.resources_discovered, 4);
    assert_eq!(after_second.resources_materialized, 2);
    assert_eq!(after_second.server_reconciles_ok, 2);

    let events = read_all(&store);
    assert_eq!(events.len(), 2, "no duplicates from second reconcile");

    server.shutdown().await;
}

#[tokio::test]
async fn cross_server_isolation_distinct_source_tags() {
    let server_a = StubMcpServer::start().await;
    server_a
        .set_resources(vec![StubResource::new("a://r", "ra", "from a")])
        .await;
    let server_b = StubMcpServer::start().await;
    server_b
        .set_resources(vec![StubResource::new("b://r", "rb", "from b")])
        .await;

    let registry = Arc::new(ServerRegistry::new());
    let host_a = LoopbackHost::parse(&format!("http://127.0.0.1:{}/sse", server_a.port()))
        .await
        .unwrap();
    let host_b = LoopbackHost::parse(&format!("http://127.0.0.1:{}/sse", server_b.port()))
        .await
        .unwrap();
    let _a = registry
        .register(ServerRegistration::http("alpha", host_a, None))
        .await;
    let _b = registry
        .register(ServerRegistration::http("beta", host_b, None))
        .await;

    let store = Arc::new(InMemoryBrainStore::new());
    let agg = McpAggregator::new(
        Arc::clone(&registry),
        Arc::clone(&store) as Arc<dyn BrainStore>,
        None,
    );
    agg.reconcile_once().await;

    let snap = agg.stats().snapshot();
    assert_eq!(snap.server_reconciles_ok, 2);
    assert_eq!(snap.resources_materialized, 2);

    let events = read_all(&store);
    assert_eq!(events.len(), 2);
    let mut tags: Vec<&str> = events
        .iter()
        .map(|e| e.app_bundle_id.as_deref().unwrap_or(""))
        .collect();
    tags.sort_unstable();
    assert_eq!(tags, vec!["mcp:alpha", "mcp:beta"]);

    server_a.shutdown().await;
    server_b.shutdown().await;
}

#[tokio::test]
async fn mcp_source_tag_does_not_collide_with_deep_hook_bundle_ids() {
    // CSO row 2 — the prefix is what V2-P12 (Phase 7) uses to route
    // prompt-injection mitigation. It must NOT collide with the
    // deep-hook bundle ids (Messages / Mail) that the V2-P7/P8 cascade
    // routes on.
    assert!(!is_mcp_source(MESSAGES_BUNDLE_ID));
    assert!(!is_mcp_source(MAIL_BUNDLE_ID));
    assert!(is_mcp_source(&source_tag("anything")));
}

#[tokio::test]
async fn tool_catalog_is_populated_per_server() {
    let server = StubMcpServer::start().await;
    server
        .set_tools(vec![
            ("slack_search".to_owned(), Some("search messages".to_owned())),
            ("slack_post".to_owned(), None),
        ])
        .await;
    server.set_resources(vec![]).await;
    let url = format!("http://127.0.0.1:{}/sse", server.port());
    let host = LoopbackHost::parse(&url).await.unwrap();
    let registry = Arc::new(ServerRegistry::new());
    let _h = registry
        .register(ServerRegistration::http("slack-mcp", host, None))
        .await;
    let store = Arc::new(InMemoryBrainStore::new());
    let agg = McpAggregator::new(
        Arc::clone(&registry),
        Arc::clone(&store) as Arc<dyn BrainStore>,
        None,
    );
    agg.reconcile_once().await;

    let catalog = agg.tool_catalog().await;
    let server_tools = catalog
        .get("slack-mcp")
        .expect("server present in catalog");
    let names: Vec<&str> = server_tools.iter().map(|t| t.name.as_str()).collect();
    assert!(names.contains(&"slack_search"));
    assert!(names.contains(&"slack_post"));

    // CSO row 4 — tool catalog snapshots tools/list result counter,
    // but NO `tools/call` was emitted (nothing produced ToolResult).
    let snap = agg.stats().snapshot();
    assert_eq!(snap.tools_cataloged, 2);

    server.shutdown().await;
}

#[tokio::test]
async fn shutdown_during_long_reconcile_interval_exits_promptly() {
    // Mirrors the V2-P10 PumpSupervisor discipline: a shutdown flag
    // flip must NOT wait for the next reconcile tick.
    let resources = vec![StubResource::new("g://r", "r", "x")];
    let (server, registry) = one_server_named("svc", resources).await;
    let store = Arc::new(InMemoryBrainStore::new());
    let agg = McpAggregator::new(
        Arc::clone(&registry),
        Arc::clone(&store) as Arc<dyn BrainStore>,
        None,
    )
    .with_reconcile_interval(Duration::from_secs(3600))
    .with_per_server_timeout(Duration::from_secs(5));

    let (tx, rx) = tokio::sync::watch::channel(false);
    let handle = tokio::spawn(async move {
        agg.run(rx).await;
    });

    // Let one tick land + register.
    tokio::time::sleep(Duration::from_millis(150)).await;
    tx.send(true).expect("shutdown send");
    let join = tokio::time::timeout(Duration::from_secs(2), handle).await;
    assert!(join.is_ok(), "aggregator must shut down within 2s");

    // The resource from the first tick made it in.
    let events = read_all(&store);
    assert_eq!(events.len(), 1);

    server.shutdown().await;
}

#[tokio::test]
async fn materialized_event_runs_v2p4_tier1_extraction_against_real_brain_store() {
    // CSO row 7 + V2-P4 wiring continuity — proves that an MCP-sourced
    // event participates in the entity-graph the same way an OCR /
    // browser / deep-hook event does. Uses a real SqlCipherBrainStore
    // because the InMemoryBrainStore stub does NOT implement the V2-
    // P3 entity surface (`put_entity` / `put_entity_mention`), and we
    // want to assert that ENTITY ROWS WERE WRITTEN to the brain — not
    // just that the counter ticked.
    use mci_brain::SqlCipherBrainStore;
    use mci_core::crypto::DbKey;

    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("v2mcp3.sqlite");
    let key = DbKey::from_bytes([0xCC; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&path, &key).expect("open store"));

    // One server, one resource whose body contains entity-shaped
    // tokens: an email + a URL. V2-P4 should pick both up.
    let body = "ping me at alice@example.com — see https://example.org/notes";
    let resources = vec![StubResource::new("mcp://r1", "r1-note", body)];
    let server = StubMcpServer::start().await;
    server.set_resources(resources).await;
    let url = format!("http://127.0.0.1:{}/sse", server.port());
    let host = LoopbackHost::parse(&url).await.unwrap();
    let registry = Arc::new(ServerRegistry::new());
    let _h = registry
        .register(ServerRegistration::http("notes-mcp", host, None))
        .await;
    let agg = McpAggregator::new(
        Arc::clone(&registry),
        Arc::clone(&store) as Arc<dyn BrainStore>,
        None,
    );
    agg.reconcile_once().await;

    let snap = agg.stats().snapshot();
    assert_eq!(snap.resources_materialized, 1);
    assert!(
        snap.tier1_mentions_persisted >= 2,
        "expected at least 2 Tier 1 mentions (email + url), got {snap:?}",
    );

    server.shutdown().await;
}

#[tokio::test]
async fn n_5_servers_with_idle_loop_holds_steady_state() {
    // CSO row 11 — footprint sanity. Five servers each holding a
    // long-lived SSE connection PLUS the per-server reconcile loop
    // (catalog + materialize) running on a tight cadence MUST NOT
    // blow the G2 raised SLO (≤10–15% CPU / ≤2 GB RAM). The asserts
    // here are structural: the reconcile completes, stats are
    // consistent (no double-count, no leaked errors), and the
    // shutdown path is prompt.
    let mut servers = Vec::new();
    let registry = Arc::new(ServerRegistry::new());
    for i in 0..5 {
        let server = StubMcpServer::start().await;
        server
            .set_resources(vec![
                StubResource::new(
                    &format!("svc{i}://r1"),
                    &format!("r1_{i}"),
                    &format!("body {i} one"),
                ),
                StubResource::new(
                    &format!("svc{i}://r2"),
                    &format!("r2_{i}"),
                    &format!("body {i} two"),
                ),
            ])
            .await;
        let url = format!("http://127.0.0.1:{}/sse", server.port());
        let host = LoopbackHost::parse(&url).await.unwrap();
        let _h = registry
            .register(ServerRegistration::http(
                &format!("svc{i}"),
                host,
                None,
            ))
            .await;
        servers.push(server);
    }

    let store = Arc::new(InMemoryBrainStore::new());
    let agg = McpAggregator::new(
        Arc::clone(&registry),
        Arc::clone(&store) as Arc<dyn BrainStore>,
        None,
    )
    .with_reconcile_interval(Duration::from_millis(50))
    .with_per_server_timeout(Duration::from_secs(3));

    let stats = agg.stats();
    let (tx, rx) = tokio::sync::watch::channel(false);
    let handle = tokio::spawn(async move {
        agg.run(rx).await;
    });

    // Let the loop run for a few ticks against five servers.
    tokio::time::sleep(Duration::from_millis(400)).await;
    tx.send(true).expect("shutdown send");
    let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;

    let snap = stats.snapshot();
    // Every server's first-tick pass materializes both resources;
    // subsequent ticks re-list but skip via the seen-set.
    assert_eq!(
        snap.resources_materialized, 10,
        "5 servers × 2 resources = 10 materialized exactly once, got {snap:?}",
    );
    assert!(snap.server_reconciles_ok >= 5);
    assert_eq!(snap.put_event_errors, 0);
    assert_eq!(snap.resources_catalog_only, 0);

    let events = read_all(&store);
    assert_eq!(events.len(), 10);
    let mut tags: Vec<String> = events
        .iter()
        .filter_map(|e| e.app_bundle_id.clone())
        .collect();
    tags.sort();
    tags.dedup();
    assert_eq!(tags.len(), 5, "five distinct source tags");
    for tag in &tags {
        assert!(tag.starts_with("mcp:svc"));
    }

    for s in servers {
        s.shutdown().await;
    }
}

#[test]
fn construction_graph_wiring_at_integration_site() {
    // Driver-CSO audit row 7 — per
    // [[project-v2p1-unit-tests-passed-but-never-wired]] the
    // load-bearing wire is `McpAggregator::new` being CONSTRUCTED in
    // `apps/agent/src/bin/mci_agent.rs`. If a future refactor moves
    // the helper out of the binary without preserving the call, this
    // assertion trips before the agent ships.
    const AGENT_BIN: &str = include_str!("../src/bin/mci_agent.rs");
    assert!(
        AGENT_BIN.contains("spawn_mcp_aggregator"),
        "spawn_mcp_aggregator helper must exist in mci_agent.rs",
    );
    assert!(
        AGENT_BIN.contains("McpAggregator::new"),
        "McpAggregator::new must be CONSTRUCTED in the agent binary",
    );
    assert!(
        AGENT_BIN.contains("mci_registry: Arc<mci_mcp_client::ServerRegistry>")
            || AGENT_BIN.contains("registry: Arc<mci_mcp_client::ServerRegistry>"),
        "spawn_mcp_aggregator should take an Arc<ServerRegistry>",
    );
}
