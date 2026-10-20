//! The person's home folder, resolved without a shared fallback.
//!
//! Storage-security review S12: with `HOME` unset, several paths used to fall
//! back to `/tmp`, a folder every local account can write, so another account
//! could create the folders first and read or replace what Hippocampus put
//! there. Every product path now resolves the home here instead: `HOME` when it
//! is set (throwaway homes in tests rely on it), else the account's entry in
//! the password database (`getpwuid_r`, through [`std::env::home_dir`]). When
//! neither names an absolute folder, callers fail closed.

use std::ffi::OsString;
use std::path::PathBuf;

/// An empty folder that only root can write. Paths built under it when the
/// home can't be resolved name nothing that exists, and every attempt to
/// create, bind or write under it fails, so nothing is ever written in a
/// shared place.
pub const UNWRITABLE_HOME: &str = "/var/empty";

/// The home folder of the account running this process: `HOME` when it is set
/// to an absolute path, else the account's home from the password database
/// (`getpwuid_r`). `None` when neither names an absolute folder: an empty or
/// relative `HOME` is refused rather than resolved against the working folder.
#[must_use]
pub fn user_home() -> Option<PathBuf> {
    // With `HOME` unset, `std::env::home_dir` asks `getpwuid_r` for this uid.
    resolve_home(std::env::var_os("HOME"), std::env::home_dir)
}

/// [`user_home`], or [`UNWRITABLE_HOME`] when the home can't be resolved, for
/// the paths that must be named before they are used. Never `/tmp`.
#[must_use]
pub fn user_home_or_unwritable() -> PathBuf {
    user_home().unwrap_or_else(|| PathBuf::from(UNWRITABLE_HOME))
}

/// The rule behind [`user_home`], with the password-database lookup passed in
/// so it can be checked without changing this process's environment.
fn resolve_home(
    home: Option<OsString>,
    password_database: impl FnOnce() -> Option<PathBuf>,
) -> Option<PathBuf> {
    match home {
        Some(value) => Some(PathBuf::from(value)).filter(|path| path.is_absolute()),
        None => password_database().filter(|path| path.is_absolute()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn no_lookup() -> Option<PathBuf> {
        panic!("HOME was set: the password database must not be asked")
    }

    #[test]
    fn home_wins_when_it_is_an_absolute_folder() {
        assert_eq!(
            resolve_home(Some("/Users/sam".into()), no_lookup),
            Some(PathBuf::from("/Users/sam"))
        );
    }

    #[test]
    fn an_empty_or_relative_home_fails_closed() {
        assert_eq!(resolve_home(Some(OsString::new()), no_lookup), None);
        assert_eq!(resolve_home(Some("relative/home".into()), no_lookup), None);
    }

    #[test]
    fn an_unset_home_asks_the_password_database() {
        assert_eq!(
            resolve_home(None, || Some(PathBuf::from("/Users/from-passwd"))),
            Some(PathBuf::from("/Users/from-passwd"))
        );
        assert_eq!(resolve_home(None, || None), None);
        assert_eq!(resolve_home(None, || Some(PathBuf::from("rel"))), None);
    }

    #[test]
    fn the_unwritable_home_is_never_a_shared_temporary_folder() {
        assert_eq!(UNWRITABLE_HOME, "/var/empty");
        assert!(!UNWRITABLE_HOME.starts_with("/tmp"));
        assert!(!UNWRITABLE_HOME.starts_with("/private/tmp"));
        assert!(user_home_or_unwritable().is_absolute());
    }
}
