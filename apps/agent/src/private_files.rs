//! Owner-only files: what every product process sets before anything else,
//! and the repair an existing install gets.
//!
//! Hippocampus's rule is 0600 for files and 0700 for folders. The first
//! launch used to create the data folder, the database and its WAL and SHM,
//! `Application Support/Hippocampus` and `Logs/MCI` with 0644 and 0755
//! (reports/e2e, finding 5; the storage review's S13). `~/Library` being
//! 0700 is what kept other accounts out. Now:
//!
//! - [`restrict_new_files`] sets the process's umask to 077 first thing in
//!   `main`, so every file and folder it creates from then on is owner-only,
//!   whichever code path makes it;
//! - [`make_owner_only`] takes group and other access off something that
//!   already exists, without following a symlink, and keeps the owner's own
//!   bits (a script stays runnable by its owner).

use std::io;
use std::os::unix::fs::PermissionsExt as _;
use std::path::Path;

/// The umask every product process runs with: no group or other access.
pub const PRIVATE_UMASK: u32 = 0o077;

/// From now on, every file this process creates is 0600 and every folder
/// 0700 (less any bits the caller asks away). Call it first in `main`: the
/// umask is process-wide and children inherit it.
pub fn restrict_new_files() {
    use rustix::fs::Mode;
    let _previous = rustix::process::umask(Mode::RWXG | Mode::RWXO);
}

/// Take group and other access off `path`. Returns whether its mode changed.
/// Missing paths and symlinks are left alone (`Ok(false)`): a link is never
/// followed out of the folder being repaired.
///
/// # Errors
/// The `lstat` or `chmod` failure, other than the path not existing.
pub fn make_owner_only(path: &Path) -> io::Result<bool> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    if metadata.file_type().is_symlink() {
        return Ok(false);
    }
    let mode = metadata.permissions().mode() & 0o7777;
    let owner_only = mode & !PRIVATE_UMASK;
    if owner_only == mode {
        return Ok(false);
    }
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(owner_only))?;
    Ok(true)
}

/// [`make_owner_only`] on the database at `db_path` and its `-wal`, `-shm`
/// and `-journal` siblings. Failures are ignored: a mode the agent can't
/// change is no reason to stop remembering, and the files are encrypted.
pub fn make_store_owner_only(db_path: &Path) {
    let _ = make_owner_only(db_path);
    for suffix in ["-wal", "-shm", "-journal"] {
        let mut sibling = db_path.as_os_str().to_owned();
        sibling.push(suffix);
        let _ = make_owner_only(Path::new(&sibling));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mode(path: &Path) -> u32 {
        std::fs::symlink_metadata(path)
            .unwrap()
            .permissions()
            .mode()
            & 0o7777
    }

    #[test]
    fn group_and_other_access_comes_off_and_the_owner_keeps_its_bits() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("mci.sqlite");
        let script = dir.path().join("hook.sh");
        let folder = dir.path().join("MCI");
        std::fs::write(&file, b"x").unwrap();
        std::fs::write(&script, b"#!/bin/sh\n").unwrap();
        std::fs::create_dir(&folder).unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o755)).unwrap();

        assert!(make_owner_only(&file).unwrap());
        assert!(make_owner_only(&script).unwrap());
        assert!(make_owner_only(&folder).unwrap());
        assert_eq!(mode(&file), 0o600);
        assert_eq!(mode(&script), 0o700);
        assert_eq!(mode(&folder), 0o700);
        assert!(
            !make_owner_only(&file).unwrap(),
            "already owner-only: nothing to change"
        );
    }

    #[test]
    fn a_symlink_is_never_followed_and_a_missing_path_is_fine() {
        let dir = tempfile::tempdir().unwrap();
        let outside = dir.path().join("outside.txt");
        std::fs::write(&outside, b"x").unwrap();
        std::fs::set_permissions(&outside, std::fs::Permissions::from_mode(0o644)).unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&outside, &link).unwrap();

        assert!(!make_owner_only(&link).unwrap());
        assert_eq!(mode(&outside), 0o644);
        assert!(!make_owner_only(&dir.path().join("absent")).unwrap());
    }

    #[test]
    fn the_store_and_its_siblings_become_owner_only() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("mci.sqlite");
        for name in ["mci.sqlite", "mci.sqlite-wal", "mci.sqlite-shm"] {
            let path = dir.path().join(name);
            std::fs::write(&path, b"x").unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        }
        make_store_owner_only(&db);
        for name in ["mci.sqlite", "mci.sqlite-wal", "mci.sqlite-shm"] {
            assert_eq!(mode(&dir.path().join(name)), 0o600, "{name}");
        }
    }
}
