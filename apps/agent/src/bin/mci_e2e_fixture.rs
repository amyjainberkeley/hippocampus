//! Hermetic fixture commands used by `scripts/e2e-clean-home.sh`.
//!
//! This binary is not bundled in Hippocampus.app. It emits one valid capture
//! frame through the shared wire encoder and exposes deletion for an isolated
//! development brain, so the shell E2E never edits SQL or invents protocol
//! bytes.

use std::io::{self, Write as _};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

use mci_brain::{EventId, SqlCipherBrainStore};
use mci_core::crypto::DbKey;
use mci_core::ipc::{encode, Message};

const CAPTURE_SENTINEL: &str =
    "Hippocampus clean home injected capture remembers the release sentinel";

fn usage() {
    eprintln!(
        "Usage: mci-e2e-fixture emit-capture | delete-event EVENT_ID\n\
         Requires MCI_DEVELOPMENT_FILE_KEY=1. delete-event also requires \
         MCI_DB_PATH and MCI_DB_KEY_HEX."
    );
}

fn development_gate() -> Result<(), &'static str> {
    if std::env::var("MCI_DEVELOPMENT_FILE_KEY").as_deref() == Ok("1") {
        Ok(())
    } else {
        Err("MCI_DEVELOPMENT_FILE_KEY=1 is required")
    }
}

fn decode_hex32(value: &str) -> Option<[u8; 32]> {
    if value.len() != 64 {
        return None;
    }
    let mut decoded = [0_u8; 32];
    for (index, pair) in value.as_bytes().chunks_exact(2).enumerate() {
        let hi = (pair[0] as char).to_digit(16)?;
        let lo = (pair[1] as char).to_digit(16)?;
        decoded[index] = u8::try_from((hi << 4) | lo).ok()?;
    }
    Some(decoded)
}

fn current_timestamp_us() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros()
        .try_into()
        .unwrap_or(u64::MAX)
}

fn bounded_app_bundle_id(value: &str) -> [u8; 64] {
    let mut output = [0_u8; 64];
    let bytes = value.as_bytes();
    let count = bytes.len().min(output.len());
    output[..count].copy_from_slice(&bytes[..count]);
    output
}

fn emit_capture() -> Result<(), String> {
    let message = Message::OCREvent {
        seq: 42_424,
        ts_us: current_timestamp_us(),
        app_bundle_id: bounded_app_bundle_id("ai.hippocampus.e2e.capture"),
        window_title: "Clean-home capture fixture".to_owned(),
        url: "https://example.invalid/hippocampus-e2e".to_owned(),
        ocr_text: CAPTURE_SENTINEL.to_owned(),
        keyframe_hash: [0_u8; 32],
    };
    io::stdout()
        .write_all(&encode(42_424, &message))
        .map_err(|error| format!("write capture frame: {error}"))
}

fn delete_event(raw_id: &str) -> Result<(), String> {
    let event_id = raw_id
        .parse::<u64>()
        .map_err(|_| "EVENT_ID must be an unsigned integer".to_owned())?;
    let db_path = std::env::var_os("MCI_DB_PATH")
        .map(PathBuf::from)
        .ok_or_else(|| "MCI_DB_PATH is required".to_owned())?;
    let key_hex =
        std::env::var("MCI_DB_KEY_HEX").map_err(|_| "MCI_DB_KEY_HEX is required".to_owned())?;
    let key_bytes = decode_hex32(&key_hex)
        .ok_or_else(|| "MCI_DB_KEY_HEX must contain exactly 64 hex characters".to_owned())?;
    let store = SqlCipherBrainStore::new(&db_path, &DbKey::from_bytes(key_bytes))
        .map_err(|error| format!("open isolated brain: {error}"))?;
    let deleted = store
        .delete_event(EventId(event_id))
        .map_err(|error| format!("delete event: {error}"))?;
    println!("{{\"deleted\":{deleted},\"event_id\":{event_id}}}");
    Ok(())
}

fn run() -> Result<(), String> {
    development_gate().map_err(str::to_owned)?;
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    match args.as_slice() {
        [command] if command == "emit-capture" => emit_capture(),
        [command, event_id] if command == "delete-event" => delete_event(event_id),
        _ => {
            usage();
            Err("unknown or incomplete fixture command".to_owned())
        }
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("mci-e2e-fixture: {error}");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mci_core::ipc::decode;

    #[test]
    fn bounded_bundle_id_is_zero_padded() {
        let source = b"ai.hippocampus.e2e.capture";
        let encoded = bounded_app_bundle_id(std::str::from_utf8(source).unwrap());
        assert_eq!(&encoded[..source.len()], source);
        assert!(encoded[source.len()..].iter().all(|byte| *byte == 0));
    }

    #[test]
    fn emitted_message_uses_current_wire_contract() {
        let message = Message::OCREvent {
            seq: 42_424,
            ts_us: 123,
            app_bundle_id: bounded_app_bundle_id("ai.hippocampus.e2e.capture"),
            window_title: "Clean-home capture fixture".to_owned(),
            url: "https://example.invalid/hippocampus-e2e".to_owned(),
            ocr_text: CAPTURE_SENTINEL.to_owned(),
            keyframe_hash: [0_u8; 32],
        };
        let bytes = encode(42_424, &message);
        let (decoded, used) = decode(&bytes).expect("decode fixture frame");
        assert_eq!(used, bytes.len());
        assert_eq!(decoded.message, message);
    }
}
