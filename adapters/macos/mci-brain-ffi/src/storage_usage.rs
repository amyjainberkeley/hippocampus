//! Content-free logical file sizes for the Privacy Dashboard.
//! Only directory handles and file metadata are accessed. No keys, file
//! contents, paths, or filenames are returned in the aggregate.

use serde::{Deserialize, Serialize};
use std::path::Path;

/// Outcome of measuring one storage component.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MeasurementStatus {
    /// All in-scope entries were measured.
    Complete,
    /// The path was absent; optional components have a known size of zero.
    Missing,
    /// Metadata or directory enumeration was inaccessible.
    Unreadable,
    /// A symbolic link was refused.
    Symlink,
    /// A non-regular file, non-directory parent, or unsupported path was refused.
    Unsupported,
    /// Some managed entries could not be measured.
    Partial,
    /// The path-depth, entry-count, or elapsed-time budget was reached.
    LimitReached,
    /// The byte count could not be represented without overflow.
    Overflow,
}

/// Logical bytes and measurement quality for a single component.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StorageMeasurement {
    /// Measured bytes, or null when unavailable. Partial values are lower bounds.
    pub logical_bytes: Option<u64>,
    /// Whether these bytes describe the entire component.
    pub status: MeasurementStatus,
}

impl StorageMeasurement {
    fn measured(bytes: u64) -> Self {
        Self {
            logical_bytes: Some(bytes),
            status: MeasurementStatus::Complete,
        }
    }

    fn unavailable(status: MeasurementStatus) -> Self {
        Self {
            logical_bytes: None,
            status,
        }
    }

    fn is_complete(&self) -> bool {
        self.logical_bytes.is_some()
            && matches!(
                self.status,
                MeasurementStatus::Complete | MeasurementStatus::Missing
            )
    }

    fn add_bytes(&mut self, bytes: u64) {
        self.logical_bytes = self
            .logical_bytes
            .and_then(|total| total.checked_add(bytes));
        if self.logical_bytes.is_none() {
            self.status = MeasurementStatus::Overflow;
        }
    }
}

/// Best-effort snapshot of managed logical storage, not allocated disk blocks.
/// Files can change during measurement; this is not an atomic filesystem snapshot.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StorageUsage {
    /// Main `SQLCipher` database file.
    pub database: StorageMeasurement,
    /// `SQLite` write-ahead log beside the database.
    pub wal: StorageMeasurement,
    /// `SQLite` shared-memory sidecar (not encrypted payload storage).
    pub shm: StorageMeasurement,
    /// Canonical screenshot blobs and managed temporary writes, without recursion.
    pub managed_blobs: StorageMeasurement,
    /// Checked sum of available bytes. Null if unavailable or overflowing.
    pub reported_total_bytes: Option<u64>,
    /// False for missing database, skipped entries, errors, limits, or overflow.
    pub complete: bool,
}

impl StorageUsage {
    fn from_components(
        database: StorageMeasurement,
        wal: StorageMeasurement,
        shm: StorageMeasurement,
        managed_blobs: StorageMeasurement,
    ) -> Self {
        let parts = [&database, &wal, &shm, &managed_blobs];
        let mut total = Some(0_u64);
        let mut any_measured = false;
        for part in parts {
            if part.status == MeasurementStatus::Overflow {
                total = None;
            }
            if let Some(bytes) = part.logical_bytes {
                any_measured = true;
                total = total.and_then(|sum| sum.checked_add(bytes));
            }
        }
        let reported_total_bytes = if any_measured { total } else { None };
        let complete = reported_total_bytes.is_some() && parts.iter().all(|p| p.is_complete());
        Self {
            database,
            wal,
            shm,
            managed_blobs,
            reported_total_bytes,
            complete,
        }
    }

    fn unavailable(status: MeasurementStatus) -> Self {
        let part = StorageMeasurement::unavailable(status);
        Self::from_components(part.clone(), part.clone(), part.clone(), part)
    }
}

/// Measure a bounded, content-free storage snapshot without following symlinks.
/// The 200ms deadline is checked between local metadata calls, not a hard
/// latency guarantee: an individual OS call cannot be interrupted here.
#[cfg(unix)]
#[must_use]
pub fn measure(brain_path: &Path) -> StorageUsage {
    let deadline = Instant::now() + Duration::from_millis(200);
    let Some(name) = brain_path.file_name() else {
        return StorageUsage::unavailable(MeasurementStatus::Unsupported);
    };
    let parent = match open_directory(brain_path.parent().unwrap_or_else(|| Path::new("."))) {
        Ok(parent) => parent,
        Err(status) => return StorageUsage::unavailable(status),
    };
    let mut wal_name = name.to_os_string();
    wal_name.push("-wal");
    let mut shm_name = name.to_os_string();
    shm_name.push("-shm");
    StorageUsage::from_components(
        measure_file(&parent, name, false),
        measure_file(&parent, wal_name.as_os_str(), true),
        measure_file(&parent, shm_name.as_os_str(), true),
        measure_blobs(&parent, 20_000, deadline),
    )
}

/// Unsupported platforms report unavailable storage rather than traversing paths.
#[cfg(not(unix))]
#[must_use]
pub fn measure(_brain_path: &Path) -> StorageUsage {
    StorageUsage::unavailable(MeasurementStatus::Unsupported)
}

/// Cheap database-only metadata for legacy summary polling; never enumerates blobs.
#[cfg(unix)]
pub(crate) fn database_bytes(brain_path: &Path) -> Option<u64> {
    let name = brain_path.file_name()?;
    let parent = open_directory(brain_path.parent()?).ok()?;
    measure_file(&parent, name, false).logical_bytes
}

#[cfg(not(unix))]
pub(crate) fn database_bytes(_brain_path: &Path) -> Option<u64> {
    None
}

#[cfg(unix)]
use rustix::{
    fd::OwnedFd,
    fs::{openat, statat, AtFlags, Dir, FileType, Mode, OFlags, CWD},
    io::Errno,
};
#[cfg(unix)]
use std::time::{Duration, Instant};

#[cfg(unix)]
const DIRECTORY_FLAGS: OFlags = OFlags::RDONLY
    .union(OFlags::DIRECTORY)
    .union(OFlags::NOFOLLOW)
    .union(OFlags::CLOEXEC);

#[cfg(unix)]
fn error_status(error: Errno) -> MeasurementStatus {
    match error {
        Errno::NOENT => MeasurementStatus::Missing,
        Errno::LOOP => MeasurementStatus::Symlink,
        Errno::NOTDIR => MeasurementStatus::Unsupported,
        _ => MeasurementStatus::Unreadable,
    }
}

#[cfg(unix)]
fn open_child_directory(
    parent: &OwnedFd,
    name: &std::ffi::OsStr,
) -> Result<OwnedFd, MeasurementStatus> {
    let metadata = statat(parent, name, AtFlags::SYMLINK_NOFOLLOW).map_err(error_status)?;
    match FileType::from_raw_mode(metadata.st_mode) {
        FileType::Symlink => return Err(MeasurementStatus::Symlink),
        FileType::Directory => (),
        _ => return Err(MeasurementStatus::Unsupported),
    }
    // NOFOLLOW still applies if the entry changes between statat and openat.
    openat(parent, name, DIRECTORY_FLAGS, Mode::empty()).map_err(error_status)
}

#[cfg(unix)]
fn open_directory(path: &Path) -> Result<OwnedFd, MeasurementStatus> {
    use std::path::Component;
    if path.components().take(65).count() > 64 {
        return Err(MeasurementStatus::LimitReached);
    }
    let mut directory = openat(
        CWD,
        if path.is_absolute() { "/" } else { "." },
        DIRECTORY_FLAGS,
        Mode::empty(),
    )
    .map_err(error_status)?;
    for component in path.components() {
        match component {
            Component::RootDir | Component::CurDir => (),
            Component::Normal(name) => directory = open_child_directory(&directory, name)?,
            Component::ParentDir | Component::Prefix(_) => {
                return Err(MeasurementStatus::Unsupported)
            }
        }
    }
    Ok(directory)
}

#[cfg(unix)]
fn measure_file(
    parent: &OwnedFd,
    name: impl rustix::path::Arg,
    optional: bool,
) -> StorageMeasurement {
    match statat(parent, name, AtFlags::SYMLINK_NOFOLLOW) {
        Ok(metadata) => match FileType::from_raw_mode(metadata.st_mode) {
            FileType::RegularFile => u64::try_from(metadata.st_size).map_or_else(
                |_| StorageMeasurement::unavailable(MeasurementStatus::Overflow),
                StorageMeasurement::measured,
            ),
            FileType::Symlink => StorageMeasurement::unavailable(MeasurementStatus::Symlink),
            _ => StorageMeasurement::unavailable(MeasurementStatus::Unsupported),
        },
        Err(Errno::NOENT) if optional => StorageMeasurement {
            logical_bytes: Some(0),
            status: MeasurementStatus::Missing,
        },
        Err(error) => StorageMeasurement::unavailable(error_status(error)),
    }
}

#[cfg(unix)]
fn managed_blob_name(name: &[u8]) -> bool {
    let digest = |bytes: &[u8]| {
        bytes.len() == 64
            && bytes
                .iter()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    };
    if let Some(stem) = name.strip_suffix(b".bin") {
        return digest(stem);
    }
    // Same canonical .<digest>.<UUID>.tmp format as the blob writer/cleanup.
    let Some(body) = name
        .strip_prefix(b".")
        .and_then(|n| n.strip_suffix(b".tmp"))
    else {
        return false;
    };
    body.len() == 101
        && digest(&body[..64])
        && body[64] == b'.'
        && body[65..].iter().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                *byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

#[cfg(unix)]
fn measure_blobs(parent: &OwnedFd, max_entries: usize, deadline: Instant) -> StorageMeasurement {
    let directory = match open_child_directory(parent, std::ffi::OsStr::new("blobs")) {
        Ok(directory) => directory,
        Err(MeasurementStatus::Missing) => {
            return StorageMeasurement {
                logical_bytes: Some(0),
                status: MeasurementStatus::Missing,
            }
        }
        Err(status) => return StorageMeasurement::unavailable(status),
    };
    let mut entries = match Dir::read_from(&directory) {
        Ok(entries) => entries,
        Err(error) => return StorageMeasurement::unavailable(error_status(error)),
    };
    let mut result = StorageMeasurement::measured(0);
    let mut visited = 0;
    loop {
        if Instant::now() >= deadline {
            result.status = MeasurementStatus::LimitReached;
            return result;
        }
        let entry = match entries.next() {
            None => return result,
            Some(Ok(entry)) => entry,
            Some(Err(_)) => {
                result.status = MeasurementStatus::Partial;
                return result;
            }
        };
        let name = entry.file_name();
        if matches!(name.to_bytes(), b"." | b"..") {
            continue;
        }
        if visited == max_entries {
            result.status = MeasurementStatus::LimitReached;
            return result;
        }
        visited += 1;
        if !managed_blob_name(name.to_bytes()) {
            continue;
        }
        let measured = measure_file(&directory, name, false);
        if let Some(bytes) = measured.logical_bytes {
            result.add_bytes(bytes);
            if result.status == MeasurementStatus::Overflow {
                return result;
            }
        } else {
            result.status = MeasurementStatus::Partial;
        }
    }
}

#[cfg(all(test, unix))]
mod tests;
