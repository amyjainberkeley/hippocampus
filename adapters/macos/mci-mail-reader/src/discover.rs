//! Mail.app V<N> data-root discovery and per-account enumeration.
//!
//! Mail-spike memo §1 found `V10` on macOS 26.5; the V<N> suffix bumps on
//! schema migrations (V9 → V10 happened with the Apple Intelligence
//! shipment). V2-P8a MUST glob-discover the highest `V<N>` directory at
//! run time. Hardcoding `V10` is a cliff at the next macOS major.

use std::fs;
use std::path::{Path, PathBuf};

use crate::error::MailReaderError;

/// Resolved Mail.app data root: `~/Library/Mail/V<N>/`.
#[derive(Debug, Clone)]
pub struct MailDataRoot {
    /// Absolute path to `V<N>/`.
    pub path: PathBuf,
    /// The integer `N` from the `V<N>` directory name. Useful for telemetry
    /// (so we can detect a schema bump in the wild without reading content).
    pub version: u32,
}

/// One Mail.app account on disk.
///
/// Each Mail-internal account is a UUID-named directory under
/// `V<N>/`. IMAP accounts and the "On My Mac" local account both follow
/// this shape. Mailbox UUIDs (one level deeper, inside `INBOX.mbox/`,
/// `Sent Messages.mbox/`, etc.) are read lazily — V2-P8a does not preload
/// every mailbox structure.
#[derive(Debug, Clone)]
pub struct MailAccount {
    /// `<ACCOUNT-UUID>` directory.
    pub root: PathBuf,
    /// The UUID string (the directory's basename).
    pub uuid: String,
}

/// Locate the highest `~/Library/Mail/V<N>/` directory on this user's home.
///
/// Falls back to the `$HOME/Library/Mail` envelope so this is testable
/// against a fake `$HOME` without monkey-patching.
pub fn find_mail_data_root(home: &Path) -> Result<MailDataRoot, MailReaderError> {
    let mail_dir = home.join("Library").join("Mail");

    let entries = match fs::read_dir(&mail_dir) {
        Ok(it) => it,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            return Err(MailReaderError::DataRootMissing(mail_dir));
        }
        Err(err) => return Err(MailReaderError::from_io(mail_dir.clone(), err)),
    };

    let mut best: Option<(u32, PathBuf)> = None;
    for entry in entries {
        let entry = match entry {
            Ok(e) => e,
            Err(err) => return Err(MailReaderError::from_io(mail_dir.clone(), err)),
        };
        let name = entry.file_name();
        let Some(name_str) = name.to_str() else {
            continue;
        };
        let Some(rest) = name_str.strip_prefix('V') else {
            continue;
        };
        // The naming convention is V<digits>. Anything else is junk
        // (e.g. PersistenceInfo.plist).
        if rest.is_empty() || !rest.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let Ok(n) = rest.parse::<u32>() else { continue };
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        match best {
            Some((cur, _)) if cur >= n => {}
            _ => best = Some((n, path)),
        }
    }

    match best {
        Some((version, path)) => Ok(MailDataRoot { path, version }),
        None => Err(MailReaderError::DataRootMissing(mail_dir)),
    }
}

/// Enumerate per-account UUID directories under a Mail data root.
///
/// The `MailData/` subdirectory under `V<N>/` is the cross-account shared
/// store (Envelope Index lives there) and is skipped here.
pub fn list_accounts(root: &MailDataRoot) -> Result<Vec<MailAccount>, MailReaderError> {
    let entries = match fs::read_dir(&root.path) {
        Ok(it) => it,
        Err(err) => return Err(MailReaderError::from_io(root.path.clone(), err)),
    };

    let mut accounts = Vec::new();
    for entry in entries {
        let entry = match entry {
            Ok(e) => e,
            Err(err) => return Err(MailReaderError::from_io(root.path.clone(), err)),
        };
        let name = entry.file_name();
        let Some(name_str) = name.to_str() else {
            continue;
        };

        // Skip MailData (the cross-account shared dir) and the persistent
        // metadata plist at `~/Library/Mail/PersistenceInfo.plist` (which
        // lives one level up but defense-in-depth here too).
        if name_str == "MailData" || name_str.starts_with('.') {
            continue;
        }
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }

        // Mail account directories are UUIDs. Loose check: no spaces, no
        // file-extension dot. (Stricter UUID parsing would be net-zero
        // value — Mail.app controls the naming.)
        if name_str.contains(' ') || name_str.contains('.') {
            continue;
        }

        accounts.push(MailAccount {
            root: path,
            uuid: name_str.to_string(),
        });
    }

    Ok(accounts)
}

/// Convenience: discover the highest `V<N>/` and list its accounts in one call.
///
/// `$HOME` resolution lives here (vs in `find_mail_data_root`) so the
/// inner functions remain unit-testable against synthesized roots.
pub fn discover_accounts() -> Result<(MailDataRoot, Vec<MailAccount>), MailReaderError> {
    let home = home_dir()?;
    let root = find_mail_data_root(&home)?;
    let accounts = list_accounts(&root)?;
    Ok((root, accounts))
}

/// Path to `MailData/Envelope Index` inside a discovered root.
#[must_use]
pub fn envelope_index_path(root: &MailDataRoot) -> PathBuf {
    root.path.join("MailData").join("Envelope Index")
}

fn home_dir() -> Result<PathBuf, MailReaderError> {
    // Minimal env-based resolver — Mail.app is per-user, $HOME is always set
    // under a TCC-permitted login session. No need to pull `dirs` for one
    // env read.
    match std::env::var_os("HOME") {
        Some(s) if !s.is_empty() => Ok(PathBuf::from(s)),
        _ => Err(MailReaderError::DataRootMissing(PathBuf::from(
            "<no $HOME>",
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::fs;
    use tempfile::tempdir;

    fn touch_dir(p: &Path) {
        fs::create_dir_all(p).expect("mkdir");
    }

    #[test]
    fn discovers_highest_vn() {
        let tmp = tempdir().unwrap();
        let mail = tmp.path().join("Library").join("Mail");
        touch_dir(&mail.join("V9"));
        touch_dir(&mail.join("V10"));
        touch_dir(&mail.join("V11"));
        // Junk that should be ignored.
        touch_dir(&mail.join("Vfoo"));
        fs::write(mail.join("PersistenceInfo.plist"), b"junk").unwrap();

        let root = find_mail_data_root(tmp.path()).unwrap();
        assert_eq!(root.version, 11);
        assert!(root.path.ends_with("Mail/V11"));
    }

    #[test]
    fn missing_root_errors() {
        let tmp = tempdir().unwrap();
        let err = find_mail_data_root(tmp.path()).unwrap_err();
        assert!(matches!(err, MailReaderError::DataRootMissing(_)));
    }

    #[test]
    fn empty_root_errors() {
        let tmp = tempdir().unwrap();
        touch_dir(&tmp.path().join("Library").join("Mail"));
        let err = find_mail_data_root(tmp.path()).unwrap_err();
        assert!(matches!(err, MailReaderError::DataRootMissing(_)));
    }

    #[test]
    fn lists_account_dirs_and_skips_maildata() {
        let tmp = tempdir().unwrap();
        let v10 = tmp.path().join("Library").join("Mail").join("V10");
        touch_dir(&v10.join("MailData"));
        touch_dir(&v10.join("AAAAAAAA-BBBB-CCCC-DDDD-000000000001"));
        touch_dir(&v10.join("AAAAAAAA-BBBB-CCCC-DDDD-000000000002"));
        // Junk that should be ignored.
        fs::write(v10.join("DefaultCounts"), b"junk").unwrap();
        touch_dir(&v10.join(".tmp"));

        let root = MailDataRoot {
            path: v10.clone(),
            version: 10,
        };
        let accounts = list_accounts(&root).unwrap();
        let mut uuids: Vec<_> = accounts.iter().map(|a| a.uuid.clone()).collect();
        uuids.sort();
        assert_eq!(
            uuids,
            vec![
                "AAAAAAAA-BBBB-CCCC-DDDD-000000000001".to_string(),
                "AAAAAAAA-BBBB-CCCC-DDDD-000000000002".to_string(),
            ]
        );
    }

    #[test]
    fn envelope_index_path_under_maildata() {
        let v10 = PathBuf::from("/tmp/Library/Mail/V10");
        let root = MailDataRoot {
            path: v10.clone(),
            version: 10,
        };
        assert_eq!(
            envelope_index_path(&root),
            v10.join("MailData").join("Envelope Index")
        );
    }
}
