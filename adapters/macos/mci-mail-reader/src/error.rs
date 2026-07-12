//! Error surface for the Mail.app read path.

use std::io;
use std::path::PathBuf;

use thiserror::Error;

/// Errors returned by the V2-P8a read API.
///
/// [`MailReaderError::AccessDenied`] is the load-bearing variant for the
/// onboarding UX: the CLI maps it to a one-line "grant Full Disk Access"
/// hint, and V2-P10 will surface the same shape in a permission gate.
#[derive(Debug, Error)]
pub enum MailReaderError {
    /// macOS Full Disk Access has not been granted to the calling process,
    /// so every read against `~/Library/Mail/V<N>/` returns `EPERM`.
    #[error(
        "Mail access denied at {path}: macOS Full Disk Access not granted. \
         Grant it in System Settings → Privacy & Security → Full Disk Access."
    )]
    AccessDenied { path: PathBuf },

    /// The expected `~/Library/Mail/V<N>/` data root does not exist.
    /// Either Mail.app has never been launched on this account, or the
    /// per-user library directory is otherwise missing.
    #[error("Mail data root not found under {0}")]
    DataRootMissing(PathBuf),

    /// emlx file did not have a valid 10-ASCII-byte length prefix or the
    /// declared length overruns the file.
    #[error("invalid emlx framing in {path}: {reason}")]
    InvalidEmlx { path: PathBuf, reason: String },

    /// Underlying I/O error (with the path attached for easier debugging
    /// at the CLI surface).
    #[error("io error at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },

    /// `rusqlite` returned an error opening or querying the Envelope Index.
    /// WAL-aware open should make `SQLITE_BUSY` rare; the CLI retries with
    /// jitter on that specific code (handled below the public API).
    #[error("envelope index error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    /// `mail-parser` could not produce a structured `Message<'_>` from the
    /// RFC 5322 body segment. In practice this is rare on Mail-written
    /// emlx (the bytes came from Mail.app which only writes valid RFC 5322).
    #[error("RFC 5322 parse failed for {path}")]
    Rfc5322 { path: PathBuf },

    /// XML plist trailer could not be parsed.
    #[error("emlx plist trailer parse failed for {path}: {source}")]
    PlistTrailer {
        path: PathBuf,
        #[source]
        source: plist::Error,
    },

    /// `FSEvents` watcher could not be set up against the requested root.
    #[error("FSEvents watcher setup failed at {path}: {source}")]
    Watcher {
        path: PathBuf,
        #[source]
        source: notify::Error,
    },
}

impl MailReaderError {
    /// Map an `std::io::Error` to a typed [`MailReaderError`], distinguishing
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
