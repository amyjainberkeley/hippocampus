//! Wire-shape test for the cycle-8.46 Privacy-Dashboard summary stats
//! payload. The Swift `SummaryStatsWire` in
//! `apps/recall-ui/Sources/RecallUIKit/FFIBrainReader.swift` decodes the
//! JSON emitted by [`mci_brain_ffi_summary_stats`] using the exact
//! snake_case keys pinned below.

use mci_brain_ffi::SummaryStatsJson;

/// A populated payload round-trips through `serde_json` and carries the
/// expected snake_case keys.
#[test]
fn summary_stats_json_round_trips_snake_case_keys() {
    let s = SummaryStatsJson {
        total_events: 12_345,
        oldest_ts_us: Some(1_700_000_000_000_000),
        newest_ts_us: Some(1_700_086_400_000_000),
        disk_bytes: 34_567_890,
    };
    let encoded = serde_json::to_string(&s).expect("encode");
    assert!(encoded.contains("\"total_events\":12345"));
    assert!(encoded.contains("\"oldest_ts_us\":1700000000000000"));
    assert!(encoded.contains("\"newest_ts_us\":1700086400000000"));
    assert!(encoded.contains("\"disk_bytes\":34567890"));

    let decoded: SummaryStatsJson = serde_json::from_str(&encoded).expect("decode");
    assert_eq!(decoded, s);
}

/// Empty store shape: total_events = 0, oldest/newest = null,
/// disk_bytes still emits (never null).
#[test]
fn summary_stats_json_empty_store_shape() {
    let s = SummaryStatsJson {
        total_events: 0,
        oldest_ts_us: None,
        newest_ts_us: None,
        disk_bytes: 0,
    };
    let encoded = serde_json::to_string(&s).expect("encode");
    assert!(encoded.contains("\"total_events\":0"));
    assert!(encoded.contains("\"oldest_ts_us\":null"));
    assert!(encoded.contains("\"newest_ts_us\":null"));
    assert!(encoded.contains("\"disk_bytes\":0"));
}
