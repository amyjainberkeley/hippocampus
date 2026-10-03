//! Read-only view of the handoff layer for `doctor`.
//!
//! Two questions: are the transcripts on disk imported, and is the packet
//! reaching the agents? The first compares transcript file mtimes with the
//! `import_cursors` table Stream A maintains; the second reads the client
//! hook files and the `handoff_deliveries` table Stream B writes. Both
//! tables are optional: a brain that predates them reports "not available
//! yet" instead of failing, because the doctor must run on any brain.
//!
//! Filesystem paths are passed in, never read from the environment, so the
//! doctor can be pointed at a temporary home in tests.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use mci_core::store::Db;

/// Where each agent writes its transcripts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscriptRoots {
    /// `~/.claude/projects`, one directory per project.
    pub claude: PathBuf,
    /// `~/.codex/sessions`, nested `YYYY/MM/DD/*.jsonl`.
    pub codex: PathBuf,
}

impl TranscriptRoots {
    /// Standard locations under `home`, with an optional Codex home override.
    #[must_use]
    pub fn for_home(home: &Path, codex_home: Option<&Path>) -> Self {
        let codex = codex_home.map_or_else(|| home.join(".codex"), Path::to_path_buf);
        Self {
            claude: home.join(".claude").join("projects"),
            codex: codex.join("sessions"),
        }
    }
}

/// Transcript files under a root, only the ones an importer would read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscriptFile {
    /// Absolute path as the importer would key it.
    pub path: PathBuf,
    /// Last modification, microseconds since the epoch.
    pub mtime_us: u64,
}

/// How far behind the import is for one root.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RootFreshness {
    /// Transcript files found.
    pub files: usize,
    /// Files whose mtime is newer than their cursor, or every file when
    /// the root has no cursor yet.
    pub newer: usize,
    /// Newest `updated_at_us` among this root's cursors.
    pub last_import_us: Option<u64>,
}

/// The newest `handoff_deliveries` row for one client.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeliveryRow {
    /// When the packet was delivered, microseconds since the epoch.
    pub ts_us: u64,
    /// `claude-code`, `codex`, `cli` or `mcp`.
    pub client: String,
    /// Project root the packet described.
    pub project_root: String,
    /// Whitespace-token estimate of the packet.
    pub token_estimate: u64,
}

/// Claude Code transcripts: `<root>/<project>/*.jsonl`, top level only.
/// Nested `subagents/` transcripts are skipped, as in `import_sessions`.
#[must_use]
pub fn claude_transcript_files(root: &Path) -> Vec<TranscriptFile> {
    let mut files = Vec::new();
    let Ok(projects) = std::fs::read_dir(root) else {
        return files;
    };
    for project in projects.flatten() {
        if !project.path().is_dir() {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(project.path()) else {
            continue;
        };
        for entry in entries.flatten() {
            push_jsonl(&mut files, &entry.path());
        }
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    files
}

/// Codex transcripts: every `*.jsonl` under `<root>`, recursively.
#[must_use]
pub fn codex_transcript_files(root: &Path) -> Vec<TranscriptFile> {
    let mut files = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                pending.push(path);
            } else {
                push_jsonl(&mut files, &path);
            }
        }
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    files
}

fn push_jsonl(files: &mut Vec<TranscriptFile>, path: &Path) {
    if path.extension().is_none_or(|ext| ext != "jsonl") {
        return;
    }
    let Ok(meta) = std::fs::metadata(path) else {
        return;
    };
    if !meta.is_file() {
        return;
    }
    let mtime_us = meta
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .and_then(|elapsed| u64::try_from(elapsed.as_micros()).ok())
        .unwrap_or(0);
    files.push(TranscriptFile {
        path: path.to_path_buf(),
        mtime_us,
    });
}

/// Compare files with cursors. `cursors` is `None` when the table is missing.
#[must_use]
pub fn root_freshness(
    root: &Path,
    files: &[TranscriptFile],
    cursors: Option<&BTreeMap<String, u64>>,
) -> RootFreshness {
    let Some(cursors) = cursors else {
        return RootFreshness {
            files: files.len(),
            newer: files.len(),
            last_import_us: None,
        };
    };
    let root_text = root.to_string_lossy();
    let last_import_us = cursors
        .iter()
        .filter(|(path, _)| path.starts_with(root_text.as_ref()))
        .map(|(_, updated)| *updated)
        .max();
    let newer = files
        .iter()
        .filter(|file| {
            cursors
                .get(file.path.to_string_lossy().as_ref())
                .is_none_or(|updated| file.mtime_us > *updated)
        })
        .count();
    RootFreshness {
        files: files.len(),
        newer,
        last_import_us,
    }
}

/// Does `name` exist as a table? Read-only, one `sqlite_master` probe.
///
/// # Errors
/// The driver's message when the probe itself fails.
pub fn table_exists(db: &Db, name: &str) -> Result<bool, String> {
    db.conn()
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1)",
            (name,),
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| error.to_string())
}

/// Every cursor as `path -> updated_at_us`. `None` when the table is missing.
///
/// # Errors
/// The driver's message when the read fails.
pub fn read_import_cursors(db: &Db) -> Result<Option<BTreeMap<String, u64>>, String> {
    if !table_exists(db, "import_cursors")? {
        return Ok(None);
    }
    let conn = db.conn();
    let mut statement = conn
        .prepare("SELECT path, updated_at_us FROM import_cursors")
        .map_err(|error| error.to_string())?;
    let rows = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })
        .map_err(|error| error.to_string())?;
    let mut cursors = BTreeMap::new();
    for row in rows {
        let (path, updated) = row.map_err(|error| error.to_string())?;
        cursors.insert(path, u64::try_from(updated).unwrap_or(0));
    }
    Ok(Some(cursors))
}

/// The newest delivery per client. `None` when the table is missing.
///
/// # Errors
/// The driver's message when the read fails.
pub fn read_last_deliveries(db: &Db) -> Result<Option<BTreeMap<String, DeliveryRow>>, String> {
    if !table_exists(db, "handoff_deliveries")? {
        return Ok(None);
    }
    let conn = db.conn();
    let mut statement = conn
        .prepare(
            "SELECT ts_us, client, project_root, token_estimate FROM handoff_deliveries \
             ORDER BY ts_us DESC, id DESC",
        )
        .map_err(|error| error.to_string())?;
    let rows = statement
        .query_map([], |row| {
            Ok(DeliveryRow {
                ts_us: u64::try_from(row.get::<_, i64>(0)?).unwrap_or(0),
                client: row.get::<_, String>(1)?,
                project_root: row.get::<_, String>(2)?,
                token_estimate: u64::try_from(row.get::<_, i64>(3)?).unwrap_or(0),
            })
        })
        .map_err(|error| error.to_string())?;
    let mut latest: BTreeMap<String, DeliveryRow> = BTreeMap::new();
    for row in rows {
        let row = row.map_err(|error| error.to_string())?;
        latest.entry(row.client.clone()).or_insert(row);
    }
    Ok(Some(latest))
}

/// `YYYY-MM-DD HH:MM` in the zone `tz_offset_secs` east of UTC.
#[must_use]
pub fn format_local_minute(ts_us: u64, tz_offset_secs: i32) -> String {
    let secs = i64::try_from(ts_us / 1_000_000).unwrap_or(i64::MAX);
    let shifted = secs.saturating_add(i64::from(tz_offset_secs)).max(0);
    let iso = crate::wall_clock::format_unix_ms(u128::from(shifted.unsigned_abs()) * 1000);
    let mut out = iso[..16].to_owned();
    out.replace_range(10..11, " ");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn touch(path: &Path) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, "{}\n").unwrap();
    }

    #[test]
    fn claude_files_are_top_level_per_project_only() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("projects");
        touch(&root.join("-Users-amy-a/one.jsonl"));
        touch(&root.join("-Users-amy-a/two.jsonl"));
        touch(&root.join("-Users-amy-a/subagents/agent.jsonl"));
        touch(&root.join("-Users-amy-b/three.jsonl"));
        touch(&root.join("-Users-amy-b/notes.txt"));
        touch(&root.join("stray.jsonl"));
        let files = claude_transcript_files(&root);
        let names: Vec<_> = files
            .iter()
            .map(|f| {
                f.path
                    .strip_prefix(&root)
                    .unwrap()
                    .to_string_lossy()
                    .into_owned()
            })
            .collect();
        assert_eq!(
            names,
            vec![
                "-Users-amy-a/one.jsonl",
                "-Users-amy-a/two.jsonl",
                "-Users-amy-b/three.jsonl"
            ]
        );
        assert!(files.iter().all(|f| f.mtime_us > 0));
    }

    #[test]
    fn codex_files_are_recursive() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("sessions");
        touch(&root.join("2026/09/25/rollout-a.jsonl"));
        touch(&root.join("2026/09/26/rollout-b.jsonl"));
        touch(&root.join("2026/09/26/ignored.json"));
        assert_eq!(codex_transcript_files(&root).len(), 2);
        assert!(codex_transcript_files(&temp.path().join("missing")).is_empty());
    }

    #[test]
    fn freshness_counts_everything_without_cursors_and_only_newer_with_them() {
        let root = Path::new("/r");
        let files = vec![
            TranscriptFile {
                path: PathBuf::from("/r/a.jsonl"),
                mtime_us: 100,
            },
            TranscriptFile {
                path: PathBuf::from("/r/b.jsonl"),
                mtime_us: 300,
            },
            TranscriptFile {
                path: PathBuf::from("/r/c.jsonl"),
                mtime_us: 50,
            },
        ];
        let none = root_freshness(root, &files, None);
        assert_eq!((none.files, none.newer, none.last_import_us), (3, 3, None));

        let empty = BTreeMap::new();
        let fresh = root_freshness(root, &files, Some(&empty));
        assert_eq!(
            (fresh.files, fresh.newer, fresh.last_import_us),
            (3, 3, None)
        );

        let mut cursors = BTreeMap::new();
        cursors.insert("/r/a.jsonl".to_owned(), 200);
        cursors.insert("/r/b.jsonl".to_owned(), 200);
        cursors.insert("/other/z.jsonl".to_owned(), 999);
        let some = root_freshness(root, &files, Some(&cursors));
        assert_eq!(some.files, 3);
        assert_eq!(some.newer, 2, "b is newer than its cursor, c has none");
        assert_eq!(some.last_import_us, Some(200), "other roots do not count");
    }

    #[test]
    fn local_minute_formatting_applies_the_offset() {
        // 2026-09-26T09:41:07Z at UTC-7 is 02:41 the same day.
        let ts_us = 1_790_415_667_000_000;
        assert_eq!(format_local_minute(ts_us, 0), "2026-09-26 09:41");
        assert_eq!(format_local_minute(ts_us, -7 * 3600), "2026-09-26 02:41");
        assert_eq!(format_local_minute(0, -3600), "1970-01-01 00:00");
    }
}
