//! Error surface for the Messages.app read path.

use std::io;
use std::path::PathBuf;

use thiserror::Error;

/// Errors returned by the V2-P7 read API.
///
/// [`MessagesReaderError::AccessDenied`] is the load-bearing variant for the
/// onboarding UX: the CLI maps it to a one-line "grant Full Disk Access"
/// hint, and V2-P10 will surface the same shape in a permission gate.
#[derive(Debug, Error)]
pub enum MessagesReaderError {
    /// macOS Full Disk Access has not been granted to the calling process,
    /// so every read against `~/Library/Messages/chat.db` returns `EPERM`.
    #[error(
        "Messages access denied at {path}: macOS Full Disk Access not granted. \
         Grant it in System Settings → Privacy & Security → Full Disk Access."
    )]
    AccessDenied { path: PathBuf },

    /// `~/Library/Messages/chat.db` does not exist. Either Messages.app has
    /// never been launched on this account, or the user has signed out of
    /// iMessage entirely.
    #[error("Messages chat.db not found at {0}")]
    ChatDbMissing(PathBuf),

    /// Underlying I/O error (with the path attached for easier debugging
    /// at the CLI surface).
    #[error("io error at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },

    /// `rusqlite` returned an error opening or querying chat.db. WAL-aware
    /// read-only open should make `SQLITE_BUSY` rare; the CLI retries with
    /// jitter on that specific code (handled below the public API).
    #[error("chat.db error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    /// `FSEvents` watcher could not be set up against the requested root.
    #[error("FSEvents watcher setup failed at {path}: {source}")]
    Watcher {
        path: PathBuf,
        #[source]
        source: notify::Error,
    },
}

impl MessagesReaderError {
    /// Map an `std::io::Error` to a typed [`MessagesReaderError`], distinguishing
    /// `PermissionDenied` (which means Full Disk Access has not been
    /// granted) from generic I/O failures.
    #[must_use]
    pub fn from_io(path: PathBuf, source: io::Error) -> Self {
        if source.kind() == io::ErrorKind::PermissionDenied {
            Self::AccessDenied { path }
        } else {
            Self::Io { path, source }
        }
    }
}
