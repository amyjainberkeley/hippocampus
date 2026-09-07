use super::*;
use std::fs::{self, File};
use std::os::unix::fs::{symlink, PermissionsExt};

fn fixture() -> (tempfile::TempDir, std::path::PathBuf) {
    let dir = tempfile::tempdir().expect("fixture directory");
    // macOS's temporary-directory ancestors can themselves be symlinks.
    let root = dir.path().canonicalize().expect("fixture physical path");
    (dir, root)
}

fn sized_file(path: impl AsRef<Path>, bytes: u64) {
    File::create(path)
        .expect("fixture file")
        .set_len(bytes)
        .expect("fixture size");
}

fn blob_name(digit: char) -> String {
    format!("{}.bin", digit.to_string().repeat(64))
}

#[test]
fn reports_logical_sizes_of_database_sidecars_and_managed_blobs() {
    let (_dir, root) = fixture();
    sized_file(root.join("mci.sqlite"), 101);
    sized_file(root.join("mci.sqlite-wal"), 202);
    sized_file(root.join("mci.sqlite-shm"), 303);
    fs::create_dir(root.join("blobs")).unwrap();
    sized_file(root.join("blobs").join(blob_name('a')), 404);
    sized_file(
        root.join("blobs").join(format!(
            ".{}.00000000-0000-0000-0000-000000000001.tmp",
            "b".repeat(64)
        )),
        505,
    );
    sized_file(root.join("blobs/notes.txt"), 9999);
    sized_file(root.join("blobs/not-a-digest.bin"), 8888);
    fs::create_dir(root.join("blobs/nested")).unwrap();
    sized_file(root.join("blobs/nested").join(blob_name('c')), 7777);

    let usage = measure(&root.join("mci.sqlite"));
    assert_eq!(usage.database.logical_bytes, Some(101));
    assert_eq!(usage.wal.logical_bytes, Some(202));
    assert_eq!(usage.shm.logical_bytes, Some(303));
    assert_eq!(usage.managed_blobs.logical_bytes, Some(909));
    assert_eq!(usage.reported_total_bytes, Some(1515));
    assert!(usage.complete);
}

#[test]
fn absent_optional_files_are_known_zero_but_missing_database_is_not_complete() {
    let (_dir, root) = fixture();
    sized_file(root.join("mci.sqlite"), 17);
    let usage = measure(&root.join("mci.sqlite"));
    assert_eq!(usage.wal.status, MeasurementStatus::Missing);
    assert_eq!(usage.wal.logical_bytes, Some(0));
    assert_eq!(usage.managed_blobs.logical_bytes, Some(0));
    assert_eq!(usage.reported_total_bytes, Some(17));
    assert!(usage.complete);

    fs::remove_file(root.join("mci.sqlite")).unwrap();
    let missing = measure(&root.join("mci.sqlite"));
    assert_eq!(missing.database.status, MeasurementStatus::Missing);
    assert_eq!(missing.database.logical_bytes, None);
    assert!(!missing.complete);
    let absent_parent = measure(&root.join("absent/mci.sqlite"));
    assert_eq!(absent_parent.reported_total_bytes, None);
    assert!(!absent_parent.complete);
}

#[test]
fn file_permissions_do_not_require_opening_database_or_blob_contents() {
    let (_dir, root) = fixture();
    let db = root.join("mci.sqlite");
    sized_file(&db, 91);
    fs::create_dir(root.join("blobs")).unwrap();
    let blob = root.join("blobs").join(blob_name('a'));
    sized_file(&blob, 19);
    fs::set_permissions(&db, fs::Permissions::from_mode(0o0)).unwrap();
    fs::set_permissions(&blob, fs::Permissions::from_mode(0o0)).unwrap();
    let usage = measure(&db);
    assert_eq!(usage.database.logical_bytes, Some(91));
    assert_eq!(usage.managed_blobs.logical_bytes, Some(19));
    assert_eq!(usage.reported_total_bytes, Some(110));
    assert!(usage.complete);
}

#[test]
fn never_follows_database_or_sidecar_symlinks() {
    let (_dir, root) = fixture();
    sized_file(root.join("outside"), 999);
    symlink(root.join("outside"), root.join("mci.sqlite")).unwrap();
    symlink(root.join("outside"), root.join("mci.sqlite-wal")).unwrap();
    let usage = measure(&root.join("mci.sqlite"));
    assert_eq!(usage.database.status, MeasurementStatus::Symlink);
    assert_eq!(usage.wal.status, MeasurementStatus::Symlink);
    assert_eq!(usage.database.logical_bytes, None);
    assert!(!usage.complete);
}

#[test]
fn never_follows_parent_or_blob_directory_symlinks() {
    let (_dir, root) = fixture();
    sized_file(root.join("mci.sqlite"), 11);
    fs::create_dir(root.join("outside")).unwrap();
    sized_file(root.join("outside").join(blob_name('a')), 9000);
    symlink(root.join("outside"), root.join("blobs")).unwrap();
    let usage = measure(&root.join("mci.sqlite"));
    assert_eq!(usage.managed_blobs.logical_bytes, None);
    assert_eq!(usage.managed_blobs.status, MeasurementStatus::Symlink);
    assert_eq!(usage.reported_total_bytes, Some(11));
    assert!(!usage.complete);

    symlink(&root, root.join("alias")).unwrap();
    let alias = measure(&root.join("alias/mci.sqlite"));
    assert_eq!(alias.reported_total_bytes, None);
    assert!(!alias.complete);
}

#[test]
fn skipped_managed_symlinks_and_nonregular_entries_leave_partial_bytes() {
    let (_dir, root) = fixture();
    sized_file(root.join("mci.sqlite"), 11);
    fs::create_dir(root.join("blobs")).unwrap();
    sized_file(root.join("blobs").join(blob_name('a')), 22);
    symlink(
        root.join("missing-target"),
        root.join("blobs").join(blob_name('b')),
    )
    .unwrap();
    fs::create_dir(root.join("blobs").join(blob_name('c'))).unwrap();
    let usage = measure(&root.join("mci.sqlite"));
    assert_eq!(usage.managed_blobs.logical_bytes, Some(22));
    assert_eq!(usage.managed_blobs.status, MeasurementStatus::Partial);
    assert_eq!(usage.reported_total_bytes, Some(33));
    assert!(!usage.complete);
}

#[test]
fn unreadable_directory_preserves_other_measurements_without_claiming_zero() {
    let (_dir, root) = fixture();
    sized_file(root.join("mci.sqlite"), 29);
    let blobs = root.join("blobs");
    fs::create_dir(&blobs).unwrap();
    fs::set_permissions(&blobs, fs::Permissions::from_mode(0o0)).unwrap();
    let usage = measure(&root.join("mci.sqlite"));
    fs::set_permissions(&blobs, fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(usage.managed_blobs.status, MeasurementStatus::Unreadable);
    assert_eq!(usage.managed_blobs.logical_bytes, None);
    assert_eq!(usage.reported_total_bytes, Some(29));
    assert!(!usage.complete);
}

#[test]
fn entry_budget_includes_unmanaged_names_and_returns_partial() {
    let (_dir, root) = fixture();
    fs::create_dir(root.join("blobs")).unwrap();
    for name in ["unknown-a", "unknown-b", "unknown-c"] {
        sized_file(root.join("blobs").join(name), 800);
    }
    let parent = open_directory(&root).unwrap();
    let measured = measure_blobs(&parent, 1, Instant::now() + Duration::from_secs(1));
    assert_eq!(measured.status, MeasurementStatus::LimitReached);
    assert_eq!(measured.logical_bytes, Some(0));
}

#[test]
fn expired_scan_deadline_returns_incomplete() {
    let (_dir, root) = fixture();
    fs::create_dir(root.join("blobs")).unwrap();
    let parent = open_directory(&root).unwrap();
    let measured = measure_blobs(&parent, 100, Instant::now());
    assert_eq!(measured.status, MeasurementStatus::LimitReached);
}

#[test]
fn pinned_directory_descriptor_is_not_redirected_by_path_replacement() {
    let (_dir, root) = fixture();
    fs::create_dir(root.join("original")).unwrap();
    fs::create_dir(root.join("other")).unwrap();
    sized_file(root.join("original/mci.sqlite"), 37);
    sized_file(root.join("other/mci.sqlite"), 999);
    let parent = open_directory(&root.join("original")).unwrap();
    fs::rename(root.join("original"), root.join("moved")).unwrap();
    symlink(root.join("other"), root.join("original")).unwrap();
    assert_eq!(
        measure_file(&parent, "mci.sqlite", false).logical_bytes,
        Some(37)
    );
}

#[test]
fn overlong_parent_walk_is_bounded() {
    let path = Path::new("/").join("part/".repeat(65)).join("mci.sqlite");
    let usage = measure(&path);
    assert_eq!(usage.database.status, MeasurementStatus::LimitReached);
    assert!(!usage.complete);
}

#[test]
fn component_and_total_overflow_cannot_wrap_or_appear_complete() {
    let mut component = StorageMeasurement::measured(u64::MAX);
    component.add_bytes(1);
    assert_eq!(component.logical_bytes, None);
    assert_eq!(component.status, MeasurementStatus::Overflow);

    let usage = StorageUsage::from_components(
        StorageMeasurement::measured(u64::MAX),
        StorageMeasurement::measured(1),
        StorageMeasurement::measured(0),
        StorageMeasurement::measured(0),
    );
    assert_eq!(usage.reported_total_bytes, None);
    assert!(!usage.complete);
}
