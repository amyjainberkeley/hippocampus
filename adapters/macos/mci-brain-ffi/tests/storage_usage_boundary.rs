//! Only synthetic, empty databases under a canonical temporary path are opened.
use mci_brain::SqlCipherBrainStore;
use mci_brain_ffi::{
    mci_brain_ffi_close, mci_brain_ffi_open, mci_brain_ffi_storage_usage,
    mci_brain_ffi_string_free, mci_brain_ffi_summary_stats, SummaryStatsJson,
};
use mci_core::crypto::DbKey;
use std::ffi::{CStr, CString};

#[test]
fn ordinary_summary_poll_does_not_measure_storage() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let path = root.join("mci.sqlite");
    let _store = SqlCipherBrainStore::new(&path, &DbKey::from_bytes([0x21; 32])).unwrap();
    let path = CString::new(path.to_str().unwrap()).unwrap();
    let key = CString::new("21".repeat(32)).unwrap();
    // Safety: the handle and C strings remain live; every returned allocation
    // is freed with its matching FFI function before the handle is closed.
    let decoded = unsafe {
        let handle = mci_brain_ffi_open(path.as_ptr(), key.as_ptr());
        assert!(!handle.is_null());
        let raw = mci_brain_ffi_summary_stats(handle);
        assert!(!raw.is_null());
        let decoded = serde_json::from_slice::<SummaryStatsJson>(CStr::from_ptr(raw).to_bytes());
        mci_brain_ffi_string_free(raw);
        mci_brain_ffi_close(handle);
        decoded.unwrap()
    };
    assert!(decoded.disk_bytes > 0);
    assert!(
        decoded.storage.is_none(),
        "polling must not enumerate screenshot storage"
    );
}

#[test]
fn explicit_storage_entrypoint_measures_blobs_and_preserves_missing_database_status() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let db_path = root.join("mci.sqlite");
    let _store = SqlCipherBrainStore::new(&db_path, &DbKey::from_bytes([0x21; 32])).unwrap();
    std::fs::create_dir_all(root.join("blobs")).unwrap();
    std::fs::File::create(root.join("blobs").join(format!("{}.bin", "a".repeat(64))))
        .unwrap()
        .set_len(73)
        .unwrap();
    let path = CString::new(db_path.to_str().unwrap()).unwrap();
    let key = CString::new("21".repeat(32)).unwrap();
    // Safety: the synthetic handle stays live across both measurements;
    // JSON allocations are freed before closing it.
    unsafe {
        let handle = mci_brain_ffi_open(path.as_ptr(), key.as_ptr());
        assert!(!handle.is_null());
        let raw = mci_brain_ffi_storage_usage(handle);
        assert!(!raw.is_null());
        let measured: serde_json::Value =
            serde_json::from_slice(CStr::from_ptr(raw).to_bytes()).unwrap();
        mci_brain_ffi_string_free(raw);
        assert_eq!(measured["managed_blobs"]["logical_bytes"], 73);
        assert_eq!(measured["complete"], true);

        std::fs::remove_file(&db_path).unwrap();
        let raw = mci_brain_ffi_storage_usage(handle);
        assert!(!raw.is_null());
        let missing: serde_json::Value =
            serde_json::from_slice(CStr::from_ptr(raw).to_bytes()).unwrap();
        mci_brain_ffi_string_free(raw);
        mci_brain_ffi_close(handle);
        assert!(missing["database"]["logical_bytes"].is_null());
        assert_eq!(missing["database"]["status"], "missing");
        assert_eq!(missing["complete"], false);
        assert_eq!(missing["managed_blobs"]["logical_bytes"], 73);
    }
}
