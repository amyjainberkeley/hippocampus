use mci_brain::{ActivityInterval, ActivityState, SqlCipherBrainStore};
use mci_brain_ffi::{
    mci_brain_activity_intervals, mci_brain_ffi_close, mci_brain_ffi_open,
    mci_brain_ffi_string_free,
};
use mci_core::crypto::DbKey;
use serde_json::Value;
use std::ffi::{CStr, CString};

#[test]
fn activity_page_clips_reports_truncation_and_omits_generation() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &DbKey::from_bytes([42; 32])).unwrap();
    for (start, end) in [(1, 101), (101, 201)] {
        store
            .append_activity_interval(&ActivityInterval {
                start_us: start,
                end_us: end,
                state: ActivityState::InputActive,
                app_bundle_id: Some("com.example.Editor".into()),
                capture_generation: "private-generation".into(),
            })
            .unwrap();
    }
    let path = CString::new(path.to_str().unwrap()).unwrap();
    let key = CString::new("2a".repeat(32)).unwrap();
    unsafe {
        let handle = mci_brain_ffi_open(path.as_ptr(), key.as_ptr());
        assert!(!handle.is_null());
        for (limit, count, truncated) in [(1, 1, true), (2, 2, false), (0, 0, true)] {
            let raw = mci_brain_activity_intervals(handle, 51, 151, limit);
            assert!(!raw.is_null());
            let bytes = CStr::from_ptr(raw).to_bytes().to_vec();
            mci_brain_ffi_string_free(raw);
            let value: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(value["intervals"].as_array().unwrap().len(), count);
            assert_eq!(value["truncated"], truncated);
            assert!(!String::from_utf8(bytes)
                .unwrap()
                .contains("private-generation"));
            if count > 0 {
                assert_eq!(value["intervals"][0]["start_us"], 51);
                assert_eq!(value["intervals"][0]["state"], "input_active");
                assert_eq!(value["intervals"][0].as_object().unwrap().len(), 4);
            }
            if count > 1 {
                assert_eq!(value["intervals"][1]["end_us"], 151);
            }
        }
        assert!(mci_brain_activity_intervals(handle, 100, 50, 1).is_null());
        assert!(mci_brain_activity_intervals(handle, 0, u64::MAX, 1).is_null());
        mci_brain_ffi_close(handle);
    }
}

#[test]
fn null_handle_is_rejected() {
    assert!(unsafe { mci_brain_activity_intervals(std::ptr::null_mut(), 0, 1, 1) }.is_null());
}
