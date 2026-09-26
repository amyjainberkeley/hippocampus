//! Synthetic GUI-demo wire only: no ingest, database, capture or image creation.

use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

use mci_core::ipc::{decode, Message};

const MINUTE_US: u64 = 60_000_000;

fn run_fixture(args: &[&str], gate: Option<&str>) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_mci-e2e-fixture"));
    command.env_clear().args(args);
    if let Some(gate) = gate {
        command.env("MCI_DEVELOPMENT_FILE_KEY", gate);
    }
    command
        .output()
        .expect("run fixture CLI without a database")
}

fn now_us() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_micros()
        .try_into()
        .unwrap()
}

#[test]
fn review_fixture_is_six_strict_wire_frames_with_bounded_times_returns_and_gap() {
    let before = now_us();
    let output = run_fixture(&["emit-review-fixture"], Some("1"));
    let after = now_us();
    assert!(output.status.success(), "review fixture CLI must succeed");
    assert!(
        output.stderr.is_empty(),
        "success must not emit diagnostics"
    );

    let expected_apps = [
        "com.mci.demo.seed.safari",
        "com.mci.demo.seed.terminal",
        "com.mci.demo.seed.vscode",
        "com.mci.demo.seed.safari",
        "com.mci.demo.seed.terminal",
        "com.mci.demo.seed.vscode",
    ];
    let offsets = [44, 39, 34, 18, 12, 3];
    let mut bytes = output.stdout.as_slice();
    let mut timestamps = Vec::new();
    let mut sequences = Vec::new();
    let mut observed_apps = Vec::new();
    for (app, minutes_ago) in expected_apps.into_iter().zip(offsets) {
        let (frame, used) =
            decode(bytes).expect("strict production wire decoder must accept each frame");
        assert!(used > 0 && used <= bytes.len());
        let Message::OCREvent {
            seq,
            ts_us,
            app_bundle_id,
            window_title,
            url,
            ocr_text,
            keyframe_hash,
        } = frame.message
        else {
            panic!("review fixture must emit only OCREvent frames");
        };
        assert_eq!(frame.seq, seq, "frame and payload sequences must agree");
        sequences.push(seq);
        timestamps.push(ts_us);
        observed_apps.push(app_bundle_id);
        assert!(ts_us >= before - 45 * MINUTE_US && ts_us <= after);
        assert!(ts_us + minutes_ago * MINUTE_US >= before);
        assert!(ts_us + minutes_ago * MINUTE_US <= after);
        assert_eq!(&app_bundle_id[..app.len()], app.as_bytes());
        assert!(app_bundle_id[app.len()..].iter().all(|byte| *byte == 0));
        assert!(window_title.starts_with("Fictional demo"));
        assert!(ocr_text.starts_with("Fictional demo:"));
        assert!(
            ocr_text.len() > 80,
            "provide useful fictional project context"
        );
        assert!(url.is_empty(), "no real browsing context");
        assert_eq!(keyframe_hash, [0; 32], "no fabricated screenshot linkage");
        bytes = &bytes[used..];
    }
    assert!(
        bytes.is_empty(),
        "exactly six frames; no trailing text or extra frames"
    );
    assert!(sequences.windows(2).all(|pair| pair[0] < pair[1]));
    let gaps: Vec<_> = timestamps
        .windows(2)
        .map(|pair| pair[1] - pair[0])
        .collect();
    assert_eq!(gaps, [5, 5, 16, 6, 9].map(|minutes| minutes * MINUTE_US));
    assert_eq!(gaps.iter().filter(|gap| **gap > 10 * MINUTE_US).count(), 1);
    let returns: Vec<_> = (1..observed_apps.len())
        .filter(|&index| {
            observed_apps[index] != observed_apps[index - 1]
                && observed_apps[..index - 1].contains(&observed_apps[index])
        })
        .collect();
    assert_eq!(
        returns,
        [3, 4, 5],
        "three sampled returns after intervening apps"
    );
}

#[test]
fn review_fixture_requires_exact_development_gate_before_emitting_bytes() {
    for gate in [
        None,
        Some(""),
        Some("0"),
        Some("true"),
        Some("01"),
        Some("1 "),
    ] {
        let output = run_fixture(&["emit-review-fixture"], gate);
        assert_eq!(output.status.code(), Some(2));
        assert!(output.stdout.is_empty(), "denied runs must emit no frames");
        assert!(String::from_utf8_lossy(&output.stderr)
            .contains("MCI_DEVELOPMENT_FILE_KEY=1 is required"));
    }
}

#[test]
fn review_fixture_rejects_extra_arguments_without_emitting_bytes() {
    let output = run_fixture(&["emit-review-fixture", "unexpected"], Some("1"));
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
}

#[test]
fn existing_emit_capture_remains_one_frame() {
    let output = run_fixture(&["emit-capture"], Some("1"));
    assert!(output.status.success());
    let (frame, used) = decode(&output.stdout).expect("decode existing fixture");
    assert_eq!(used, output.stdout.len());
    let Message::OCREvent {
        seq,
        app_bundle_id,
        ocr_text,
        keyframe_hash,
        ..
    } = frame.message
    else {
        panic!("existing capture fixture must remain an OCREvent");
    };
    assert_eq!(seq, 42_424);
    assert_eq!(frame.seq, seq);
    assert_eq!(&app_bundle_id[..26], b"ai.hippocampus.e2e.capture");
    assert_eq!(
        ocr_text,
        "Hippocampus clean home injected capture remembers the release sentinel"
    );
    assert_eq!(keyframe_hash, [0; 32]);
}
