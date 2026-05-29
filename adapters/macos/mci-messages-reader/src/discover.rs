//! Messages.app data-root discovery.
//!
//! `chat.db` lives at the fixed path `~/Library/Messages/chat.db` on every
//! macOS release through 26. Unlike Mail.app's V<N>/ pathway there is no
//! schema-tagged directory to discover — the file path has been stable
//! since macOS Mountain Lion (2012). We still resolve `$HOME` at run time
//! (not at build time) so the crate is testable under a fake home.

use std::fs;
use std::path::{Path, PathBuf};

use crate::error::MessagesReaderError;

/// Resolved chat.db location.
#[derive(Debug, Clone)]
pub struct ChatDbLocation {
    /// Absolute path to `chat.db`.
    pub path: PathBuf,
    /// Absolute path to the containing directory (`~/Library/Messages/`).
    /// Useful for the `FSEvents` watcher root.
    pub root: PathBuf,
}

/// Locate `chat.db` under a given home directory.
///
/// Returns [`MessagesReaderError::ChatDbMissing`] when the path does not
/// exist; returns [`MessagesReaderError::AccessDenied`] when the directory
/// exists but we cannot read it (Full Disk Access not granted to the
/// calling process).
pub fn find_chat_db(home: &Path) -> Result<ChatDbLocation, MessagesReaderError> {
    let root = home.join("Library").join("Messages");
    let path = root.join("chat.db");

    // Probe the containing directory first so we can distinguish
    // "Messages.app never ran on this account" (ENOENT on the dir) from
    // "Full Disk Access not granted" (EPERM on the dir).
    match fs::metadata(&root) {
        Ok(md) if !md.is_dir() => {
            return Err(MessagesReaderError::ChatDbMissing(root));
        }
        Ok(_) => {}
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            return Err(MessagesReaderError::ChatDbMissing(root));
        }
        Err(err) => return Err(MessagesReaderError::from_io(root.clone(), err)),
    }

    match fs::metadata(&path) {
        Ok(md) if md.is_file() => Ok(ChatDbLocation { path, root }),
        Ok(_) => Err(MessagesReaderError::ChatDbMissing(path)),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            Err(MessagesReaderError::ChatDbMissing(path))
        }
        Err(err) => Err(MessagesReaderError::from_io(path, err)),
    }
}

/// Convenience: resolve `$HOME` and discover `chat.db` in one call.
///
/// `$HOME` resolution lives here (vs in `find_chat_db`) so the inner
/// function remains unit-testable against synthesized roots.
pub fn discover_chat_db() -> Result<ChatDbLocation, MessagesReaderError> {
    let home = home_dir()?;
    find_chat_db(&home)
}

fn home_dir() -> Result<PathBuf, MessagesReaderError> {
    // Minimal env-based resolver — Messages.app is per-user, $HOME is always
    // set under a TCC-permitted login session. No need to pull `dirs` for one
    // env read.
    match std::env::var_os("HOME") {
        Some(s) if !s.is_empty() => Ok(PathBuf::from(s)),
        _ => Err(MessagesReaderError::ChatDbMissing(PathBuf::from(
            "<no $HOME>",
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use tempfile::tempdir;

    #[test]
    fn discovers_chat_db_when_present() {
        let tmp = tempdir().unwrap();
        let root = tmp.path().join("Library").join("Messages");
        fs::create_dir_all(&root).unwrap();
        let db = root.join("chat.db");
        fs::write(&db, b"SQLite format 3\0").unwrap();

        let loc = find_chat_db(tmp.path()).unwrap();
        assert_eq!(loc.path, db);
        assert_eq!(loc.root, root);
    }

    #[test]
    fn missing_messages_dir_errors() {
        let tmp = tempdir().unwrap();
        let err = find_chat_db(tmp.path()).unwrap_err();
        assert!(matches!(err, MessagesReaderError::ChatDbMissing(_)));
    }

    #[test]
    fn missing_chat_db_with_present_dir_errors() {
        let tmp = tempdir().unwrap();
        let root = tmp.path().join("Library").join("Messages");
        fs::create_dir_all(&root).unwrap();
        let err = find_chat_db(tmp.path()).unwrap_err();
        match err {
            MessagesReaderError::ChatDbMissing(p) => {
                assert!(p.ends_with("chat.db"));
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }
}
