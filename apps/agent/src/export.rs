//! Writing an export (storage-security review S8): a plaintext copy of the
//! memory the person asked for, so it is private to them from the moment it
//! exists, and complete or absent, never half written.

use std::io::Write as _;
use std::path::Path;

/// Write the lines `fill` produces to `out`: first to a new temporary file
/// beside it, created mode 0600 (never readable by another account, not
/// even for a moment), synced, then renamed over `out`. Returns what `fill`
/// returns. On any failure the temporary file goes and `out` is untouched.
///
/// # Errors
/// The folder can't be written, a line can't be written, or `fill` failed.
pub fn write_private_jsonl<F>(out: &Path, fill: F) -> std::io::Result<u64>
where
    F: FnOnce(&mut dyn FnMut(&str) -> std::io::Result<()>) -> std::io::Result<u64>,
{
    let dir = out
        .parent()
        .filter(|dir| !dir.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let name = out
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("export");
    let mut nonce = [0u8; 8];
    let _ = getrandom::fill(&mut nonce);
    let suffix: String = nonce.iter().map(|byte| format!("{byte:02x}")).collect();
    let temporary = dir.join(format!(".{name}.{suffix}.tmp"));
    let result = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let file = options.open(&temporary)?;
        let mut writer = std::io::BufWriter::new(file);
        let count = {
            let mut sink = |line: &str| -> std::io::Result<()> {
                writer.write_all(line.as_bytes())?;
                writer.write_all(b"\n")
            };
            fill(&mut sink)?
        };
        let file = writer
            .into_inner()
            .map_err(std::io::IntoInnerError::into_error)?;
        file.sync_all()?;
        std::fs::rename(&temporary, out)?;
        Ok(count)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn mode(path: &Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn an_export_is_private_complete_and_replaces_what_was_chosen() {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("hippocampus-export.jsonl");
        std::fs::write(&out, b"an older file the person chose to replace").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&out, std::fs::Permissions::from_mode(0o644)).unwrap();
        }
        let count = write_private_jsonl(&out, |sink| {
            for n in 0..1_000 {
                sink(&format!("{{\"event_id\":{n}}}"))?;
            }
            Ok(1_000)
        })
        .unwrap();
        assert_eq!(count, 1_000);
        let text = std::fs::read_to_string(&out).unwrap();
        assert_eq!(text.lines().count(), 1_000);
        #[cfg(unix)]
        assert_eq!(mode(&out), 0o600, "only this user can read an export");
        assert_eq!(
            std::fs::read_dir(dir.path()).unwrap().count(),
            1,
            "no temporary file left"
        );
    }

    #[test]
    fn a_failed_export_leaves_nothing_and_keeps_the_old_file() {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("keep.jsonl");
        std::fs::write(&out, b"kept").unwrap();
        let error = write_private_jsonl(&out, |sink| {
            sink("{}")?;
            Err(std::io::Error::other("the memory could not be read"))
        });
        assert!(error.is_err());
        assert_eq!(std::fs::read(&out).unwrap(), b"kept");
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
    }
}
