use mci_agent::context_packet::{ContextEvidence, EvidencePriority};
use mci_agent::retention_worker::load_retention_config;
use mci_brain::retention_purger::RetentionConfig;
use mci_brain::{BrainStore, EventSource, SqlCipherBrainStore};
use mci_brain::{Event, EventId};
use mci_core::crypto::DbKey;
use std::sync::Arc;

fn event() -> Event {
    Event {
        id: EventId(1),
        ts_us: 1_000_000,
        app_bundle_id: Some("com.anthropic.claude-code".into()),
        window_title: None,
        url: None,
        text: "Imported conversation".into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    }
}

#[test]
fn event_without_provenance_is_unknown_even_with_a_recognizable_app() {
    let evidence = ContextEvidence::from_event(&event(), EvidencePriority::Recent, None);
    assert_eq!(evidence.source_kind, "unknown");
}

#[test]
fn fresh_retention_is_ninety_days() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(
        load_retention_config(&dir.path().join("retention.json")).unwrap(),
        RetentionConfig::Days(90)
    );
}

#[test]
fn legacy_finite_retention_requires_review() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("retention.json");
    std::fs::write(&path, r#"{"mode":"sevenDays","days":null}"#).unwrap();
    assert!(load_retention_config(&path).is_err());
}

struct Clock(&'static str);
impl mci_agent::wall_clock::WallClock for Clock {
    fn now_rfc3339(&self) -> String {
        self.0.into()
    }
}

#[derive(Default)]
struct StepClock(std::sync::atomic::AtomicU64);
impl mci_agent::wall_clock::WallClock for StepClock {
    fn now_rfc3339(&self) -> String {
        mci_agent::wall_clock::format_unix_ms(
            1_788_640_000_000
                + u128::from(self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst)),
        )
    }
}

#[test]
fn receipt_counts_imports_separately_and_tracks_retention() {
    use mci_agent::capture_status::{CaptureStatus, CaptureStatusWriter};
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(
        SqlCipherBrainStore::new(
            &dir.path().join("brain.sqlite"),
            &DbKey::from_bytes([42; 32]),
        )
        .unwrap(),
    );
    store
        .put_event_with_source(&event(), EventSource::TranscriptImport)
        .unwrap();
    let path = dir.path().join("capture-status.json");
    let writer = CaptureStatusWriter::new(Arc::clone(&store), path.clone(), true);
    let clock = Clock("2026-09-05T12:00:00.000Z");
    writer.refresh(&clock);
    let read = || serde_json::from_slice::<CaptureStatus>(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(read().stored_frame_count, 0);
    assert_eq!(read().last_stored_frame_at, None);
    let mut screen = event();
    screen.keyframe_blob = Some("ab".repeat(32));
    store
        .put_event_with_source(&screen, EventSource::ScreenOcr)
        .unwrap();
    writer.stored_frame(&clock);
    assert_eq!(read().stored_frame_count, 1);
    assert_eq!(read().stored_screenshot_count, 1);
    assert_eq!(
        read().last_stored_frame_at.as_deref(),
        Some("1970-01-01T00:00:01.000Z")
    );
    writer.suppressed(mci_core::ipc::RedactionReason::FailsafeUnknown, &clock);
    assert_eq!(
        read().suppression_reason.as_deref(),
        Some("failsafe-unknown")
    );
    writer.refresh(&Clock("2026-09-05T12:00:30.000Z"));
    assert_eq!(
        read().last_stored_frame_at.as_deref(),
        Some("1970-01-01T00:00:01.000Z")
    );
    assert_eq!(read().updated_at, "2026-09-05T12:00:30.000Z");
    assert_eq!(
        read().suppression_reason.as_deref(),
        Some("failsafe-unknown")
    );
    store.delete_events_in_range(0, 2_000_000).unwrap();
    writer.refresh(&clock);
    assert_eq!(read().stored_frame_count, 0);
    assert_eq!(read().stored_screenshot_count, 0);
    assert_eq!(read().last_stored_frame_at, None);
    let json: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    let keys: std::collections::BTreeSet<_> = json
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(
        keys,
        [
            "schema_version",
            "updated_at",
            "last_stored_frame_at",
            "stored_frame_count",
            "stored_screenshot_count",
            "suppression_reason",
            "blocked_reason"
        ]
        .into_iter()
        .collect()
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}

#[test]
fn imports_retain_provenance_through_live_context() {
    use mci_agent::context_packet::ContextBudget;
    use mci_agent::mcp::{BrainReader, LiveBrainReader};
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("brain.sqlite");
    let key = DbKey::from_bytes([43; 32]);
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();
    let transcripts = dir.path().join("transcripts");
    let project = transcripts.join("project");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(project.join("session.jsonl"), r#"{"type":"user","timestamp":"2026-09-01T10:00:00Z","message":{"content":"Please review the exact release checklist."}}"#).unwrap();
    let stats = mci_agent::import_sessions::import_sessions(&store, &transcripts, |_| {}).unwrap();
    assert_eq!(stats.events_written, 1);
    let record = store.recent_events(1).unwrap().remove(0);
    assert_eq!(
        store.event_source(record.id).unwrap(),
        EventSource::TranscriptImport
    );
    let reader = LiveBrainReader::open(&path, &key).unwrap();
    let packet = reader.context(None, ContextBudget::new(500, 5)).unwrap();
    assert_eq!(packet.citations.len(), 1);
    assert_eq!(packet.citations[0].source_kind, "transcript_import");
    let server = mci_agent::mcp::Server::new(Arc::new(reader));
    for (name, arguments, field) in [
        (
            "mci_events_since",
            serde_json::json!({"ts_us": 0}),
            "events",
        ),
        (
            "mci_events_by_app",
            serde_json::json!({"app_bundle_id": "com.anthropic.claude-code"}),
            "events",
        ),
        (
            "mci_recall",
            serde_json::json!({"query": "release checklist"}),
            "related_context",
        ),
    ] {
        let request = serde_json::from_value(serde_json::json!({
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        }))
        .unwrap();
        let result = server.dispatch(request).unwrap().result.unwrap();
        assert_eq!(
            result[field][0]["source_kind"], "transcript_import",
            "{name}: {result}"
        );
        assert!(result["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("transcript_import"));
    }
}

#[test]
fn browser_and_merged_ocr_producers_record_distinct_sources() {
    use mci_agent::brain_ingest::{BrainIngestor, BrainPump, IngestOutcome};
    use mci_agent::page_content::PageContentCache;
    use mci_core::ipc::Message;
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(
        SqlCipherBrainStore::new(
            &dir.path().join("brain.sqlite"),
            &DbKey::from_bytes([46; 32]),
        )
        .unwrap(),
    );
    let cache = PageContentCache::with_ttl(std::time::Duration::from_secs(3600));
    cache.insert(
        "https://example.test".into(),
        "Structured browser text".into(),
        "Page".into(),
        "chrome".into(),
    );
    let pump = BrainPump::with_page_cache(store.clone(), None, cache);
    let page = Message::PageContentEvent {
        seq: 1,
        ts_us: 1000,
        url: "https://example.test".into(),
        title: "Page".into(),
        full_text: "Structured browser text".into(),
        source_browser: "chrome".into(),
        tab_id: 1,
    };
    let merged = Message::OCREvent {
        seq: 2,
        ts_us: 2000,
        app_bundle_id: [0; 64],
        window_title: String::new(),
        url: "https://example.test".into(),
        ocr_text: "Visible screen text".into(),
        keyframe_hash: [0; 32],
    };
    for (message, expected) in [
        (page, EventSource::BrowserPage),
        (merged, EventSource::BrowserPageWithOcr),
    ] {
        let IngestOutcome::Stored { id, .. } = pump.ingest_ocr_event(&message).unwrap() else {
            panic!("expected stored");
        };
        assert_eq!(store.event_source(id).unwrap(), expected);
    }
    assert_eq!(store.capture_storage_stats().unwrap().stored_frame_count, 1);
}

#[test]
fn legacy_retention_skips_all_deletion_until_review_and_v2_is_enforced() {
    use mci_agent::retention_worker::run_retention_cycle;
    let dir = tempfile::tempdir().unwrap();
    let store = SqlCipherBrainStore::new(
        &dir.path().join("brain.sqlite"),
        &DbKey::from_bytes([44; 32]),
    )
    .unwrap();
    store
        .put_event_with_source(&event(), EventSource::TranscriptImport)
        .unwrap();
    let config = dir.path().join("retention.json");
    let now = 100 * 86_400_000_000;
    for legacy in [
        r#"{"mode":"sevenDays"}"#,
        r#"{"schema_version":1,"mode":"thirtyDays"}"#,
        r#"{"mode":"custom","days":90}"#,
    ] {
        std::fs::write(&config, legacy).unwrap();
        let error =
            run_retention_cycle(&store, &config, std::time::Duration::ZERO, now).unwrap_err();
        assert!(error.to_string().contains("retention_review_required"));
        assert_eq!(store.stats().unwrap().event_count, 1);
        assert_eq!(std::fs::read_to_string(&config).unwrap(), legacy);
    }
    std::fs::write(&config, r#"{"schema_version":2,"mode":"ninetyDays"}"#).unwrap();
    assert_eq!(
        load_retention_config(&config).unwrap(),
        RetentionConfig::Days(90)
    );
    assert_eq!(
        run_retention_cycle(&store, &config, std::time::Duration::ZERO, now)
            .unwrap()
            .0
            .events_deleted,
        1
    );
    std::fs::write(&config, r#"{"schema_version":3,"mode":"sevenDays"}"#).unwrap();
    assert!(load_retention_config(&config).is_err());
}

#[tokio::test]
async fn runner_publishes_commit_and_suppression_receipts_before_eof() {
    use mci_agent::brain_ingest::BrainPump;
    use mci_agent::capture_status::{CaptureStatus, CaptureStatusWriter};
    use mci_agent::health_log::{HealthLog, HealthLogConfig};
    use mci_core::ipc::{Message, RedactionReason};
    use tokio::io::AsyncWriteExt;
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(
        SqlCipherBrainStore::new(
            &dir.path().join("brain.sqlite"),
            &DbKey::from_bytes([45; 32]),
        )
        .unwrap(),
    );
    let path = dir.path().join("capture-status.json");
    let status = CaptureStatusWriter::new(Arc::clone(&store), path.clone(), true);
    let pump = BrainPump::new(store as Arc<dyn BrainStore>, None);
    let (device, _) = mci_agent::device_id::load_or_generate(dir.path().join("device-id"))
        .await
        .unwrap();
    let log = HealthLog::new(HealthLogConfig {
        path: dir.path().join("health.jsonl"),
        max_bytes: 100_000,
    });
    let (mut tx, mut rx) = tokio::io::duplex(8192);
    let task = tokio::spawn(async move {
        mci_agent::runner::drain_with_capture_status(
            &mut rx,
            &log,
            &StepClock::default(),
            &device,
            Some(&pump),
            Some(&status),
        )
        .await
        .unwrap()
    });
    let mut app_bundle_id = [0; 64];
    app_bundle_id[..11].copy_from_slice(b"private-app");
    let ocr = Message::OCREvent {
        seq: 1,
        ts_us: 1_000_000,
        app_bundle_id,
        window_title: "private-title".into(),
        url: String::new(),
        ocr_text: "private text".into(),
        keyframe_hash: [1; 32],
    };
    tx.write_all(&mci_core::ipc::wire::encode(1, &ocr))
        .await
        .unwrap();
    async fn receipt(path: &std::path::Path, suppressed: bool) -> CaptureStatus {
        tokio::time::timeout(std::time::Duration::from_secs(15), async {
            loop {
                if let Ok(bytes) = std::fs::read(path) {
                    let value: CaptureStatus = serde_json::from_slice(&bytes).unwrap();
                    if value.stored_frame_count == 1
                        && value.suppression_reason.is_some() == suppressed
                    {
                        break value;
                    }
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap()
    }
    assert_eq!(receipt(&path, false).await.stored_screenshot_count, 1);
    assert!(
        !task.is_finished(),
        "receipt must be published during capture"
    );
    tx.write_all(&mci_core::ipc::wire::encode(
        2,
        &Message::PrivacyTombstone {
            ts_us: 2_000_000,
            app_bundle: "private-app".into(),
            reason: RedactionReason::FailsafeUnknown,
        },
    ))
    .await
    .unwrap();
    assert_eq!(
        receipt(&path, true).await.suppression_reason.as_deref(),
        Some("failsafe-unknown")
    );
    assert!(!task.is_finished());
    let before_health = receipt(&path, true).await.updated_at;
    tx.write_all(&mci_core::ipc::wire::encode(
        3,
        &Message::HelperHealth {
            uptime_ms: 99_999,
            frames_delivered: 10_000,
            frames_suppressed: 8_000,
            frames_redacted_by_failsafe: 7_000,
            cascade_forced_count: 0,
            frames_dropped_backpressure: 0,
            frames_dropped_late_ack: 0,
            frames_encode_failed: 0,
            frames_focus_race_dropped: 0,
            failsafe_by_app: vec![],
            cpu_pct_micro: 0,
            rss_bytes: 0,
            tracker_alive_at_us: 0,
        },
    ))
    .await
    .unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(15), async {
        loop {
            let value = receipt(&path, true).await;
            if value.updated_at != before_health {
                assert_eq!(
                    value.stored_frame_count, 1,
                    "helper counters must not replace DB counts"
                );
                assert_eq!(
                    value.last_stored_frame_at.as_deref(),
                    Some("1970-01-01T00:00:01.000Z")
                );
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    tx.shutdown().await.unwrap();
    let stats = task.await.unwrap();
    assert_eq!(stats.frames_to_brain, 1);
    assert_eq!(stats.frames_logged, 1);
}
