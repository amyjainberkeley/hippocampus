//! What the two transcript importers share.
//!
//! `import_sessions` (Claude Code) and `import_codex` (Codex) read different
//! JSONL dialects but write the same thing: ordinary `Event` rows with one
//! context header line, resumable per file through `import_cursors`
//! (migration 0011). This module holds that common half so the two
//! importers cannot drift apart on the header format, the skip rules, the
//! mutating-call detection or the resume logic. `docs/handoff/CONTRACT.md`
//! section 1 is the specification.
//!
//! # Header line
//!
//! ```text
//! [app={claude-code|codex} | title={label} · {role} | url={cwd}#{branch} | session={id} | src={path}:{line}]
//! ```
//!
//! `src` cites the transcript file and the 1-based line the event came from,
//! so a packet built from these events can point at its evidence.
//!
//! # Resume
//!
//! A cursor stores the first unconsumed byte and the number of complete
//! lines already consumed. A file that grew is read from that byte; a file
//! whose size and mtime are unchanged is not opened; a file that shrank was
//! rewritten and is read from the start again (duplicates are accepted in
//! that rare case and logged). A trailing line without a newline that does
//! not parse is a session still being written and is left for the next run.

use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::Path;
use std::time::{Instant, SystemTime};

use mci_brain::{BrainStore, Event, EventId, EventSource, ImportCursor, SqlCipherBrainStore};

/// Body lines of a `tool` event are cut at this many characters.
pub const TOOL_LINE_MAX_CHARS: usize = 200;

/// How often the per-line loop looks at the clock. Cheap either way; this
/// only keeps `Instant::now()` off the hot path.
const DEADLINE_CHECK_EVERY: u64 = 128;

/// What an import pass did. Every counter is additive across roots.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ImportStats {
    /// Files opened and read, in full or from a cursor.
    pub files_scanned: u64,
    /// Files continued from a stored cursor.
    pub files_resumed: u64,
    /// Files not opened because size and mtime matched the cursor.
    pub files_unchanged: u64,
    /// Files re-read from the start because they were smaller than the
    /// cursor said. Duplicates are possible for these and are logged.
    pub files_rewound: u64,
    /// Files skipped because they are agent-to-agent traffic (Claude
    /// `subagents/` directories, Codex threads with a `parent_thread_id`).
    pub files_skipped_subagent: u64,
    /// JSONL records parsed.
    pub records_read: u64,
    /// Events written to the brain, `tool` events included.
    pub events_written: u64,
    /// The subset of `events_written` that are `tool` events.
    pub tool_events_written: u64,
    /// Conversation records with no usable text and no mutating call.
    pub skipped_no_text: u64,
    /// User records that were system-injected (`<...>`, file lists,
    /// interruption notices) rather than typed by a person.
    pub skipped_injected: u64,
    /// Claude records flagged `isSidechain`.
    pub skipped_sidechain: u64,
    /// Claude records flagged `isMeta`.
    pub skipped_meta: u64,
    /// Lines that were not valid JSON. A truncated tail is normal for a
    /// session still being written, so this is counted, not fatal.
    pub malformed_lines: u64,
    /// Bytes read from transcript files.
    pub bytes_read: u64,
    /// The pass stopped early because its deadline passed. Cursors are
    /// stored up to the last complete line, so the next pass continues.
    pub deadline_hit: bool,
}

impl ImportStats {
    /// Fold another pass into this one.
    pub fn absorb(&mut self, other: &ImportStats) {
        self.files_scanned += other.files_scanned;
        self.files_resumed += other.files_resumed;
        self.files_unchanged += other.files_unchanged;
        self.files_rewound += other.files_rewound;
        self.files_skipped_subagent += other.files_skipped_subagent;
        self.records_read += other.records_read;
        self.events_written += other.events_written;
        self.tool_events_written += other.tool_events_written;
        self.skipped_no_text += other.skipped_no_text;
        self.skipped_injected += other.skipped_injected;
        self.skipped_sidechain += other.skipped_sidechain;
        self.skipped_meta += other.skipped_meta;
        self.malformed_lines += other.malformed_lines;
        self.bytes_read += other.bytes_read;
        self.deadline_hit |= other.deadline_hit;
    }
}

/// Errors an import can surface.
#[derive(Debug, thiserror::Error)]
pub enum ImportError {
    /// The transcript root does not exist or cannot be listed.
    #[error("import: cannot read {0}")]
    Root(String),
    /// A store write failed fatally.
    #[error("import: store: {0}")]
    Store(String),
}

/// Which agent wrote the transcript.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Agent {
    /// Claude Code, `~/.claude/projects`.
    ClaudeCode,
    /// Codex, `~/.codex/sessions`.
    Codex,
}

impl Agent {
    /// The `app=` value in the header.
    #[must_use]
    pub const fn tag(self) -> &'static str {
        match self {
            Agent::ClaudeCode => "claude-code",
            Agent::Codex => "codex",
        }
    }

    /// The `app_bundle_id` stored on the event.
    #[must_use]
    pub const fn bundle_id(self) -> &'static str {
        match self {
            Agent::ClaudeCode => "com.anthropic.claude-code",
            Agent::Codex => "com.openai.codex",
        }
    }
}

/// Who a transcript event is attributed to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// Text the person typed.
    User,
    /// Text the agent showed the person.
    Assistant,
    /// A mutating tool call the agent made.
    Tool,
}

impl Role {
    /// The role label used in `window_title`.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Role::User => "user",
            Role::Assistant => "assistant",
            Role::Tool => "tool",
        }
    }
}

/// Everything the header line and the event columns are built from.
#[derive(Debug, Clone, Copy)]
pub struct EventContext<'a> {
    /// Which agent wrote the transcript.
    pub agent: Agent,
    /// Short project label, normally the last path component of `cwd`.
    pub label: &'a str,
    /// Session working directory, absolute. Empty when unknown.
    pub cwd: &'a str,
    /// Git branch. Empty when unknown (Codex has no branch field).
    pub branch: &'a str,
    /// Claude `sessionId` or Codex `session_meta.payload.id`.
    pub session: &'a str,
    /// Absolute transcript path.
    pub src_path: &'a str,
    /// 1-based line in the transcript.
    pub line_no: u64,
}

impl EventContext<'_> {
    /// `{label} · {role}`, the event's `window_title`.
    #[must_use]
    pub fn title(&self, role: Role) -> String {
        format!("{} · {}", self.label, role.label())
    }

    /// The header line, without its trailing newline.
    #[must_use]
    pub fn header(&self, role: Role) -> String {
        format!(
            "[app={} | title={} | url={}#{} | session={} | src={}:{}]",
            self.agent.tag(),
            self.title(role),
            self.cwd,
            self.branch,
            self.session,
            self.src_path,
            self.line_no,
        )
    }

    /// Build the event row for `body`, header first.
    #[must_use]
    pub fn event(&self, role: Role, ts_us: u64, body: &str) -> Event {
        Event {
            id: EventId(0),
            ts_us,
            app_bundle_id: Some(self.agent.bundle_id().to_string()),
            window_title: Some(self.title(role)),
            url: if self.cwd.is_empty() {
                None
            } else {
                Some(self.cwd.to_string())
            },
            text: format!("{}\n{body}", self.header(role)),
            embedding: None,
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
        }
    }
}

/// Write one transcript event and count it.
///
/// # Errors
/// [`ImportError::Store`] if the write fails.
pub fn write_event(
    store: &SqlCipherBrainStore,
    event: &Event,
    role: Role,
    stats: &mut ImportStats,
) -> Result<(), ImportError> {
    store
        .put_event_with_source(event, EventSource::TranscriptImport)
        .map_err(|e| ImportError::Store(e.to_string()))?;
    stats.events_written += 1;
    if role == Role::Tool {
        stats.tool_events_written += 1;
    }
    Ok(())
}

/// The last path component, for a project label. `/` and empty give `""`.
#[must_use]
pub fn basename(path: &str) -> &str {
    path.trim_end_matches('/').rsplit('/').next().unwrap_or("")
}

/// RFC3339 UTC to microseconds since epoch.
///
/// Hand-rolled to avoid taking a date dependency for one field. Returns
/// `None` on anything unexpected, so a malformed record is skipped rather
/// than silently stamped with the wrong time and sorted into the wrong day.
/// Accepts `YYYY-MM-DDTHH:MM:SS[.fff...]Z`; fractional seconds are kept to
/// microsecond precision.
#[must_use]
#[allow(clippy::many_single_char_names)]
pub fn parse_ts_us(ts: &str) -> Option<u64> {
    let b = ts.as_bytes();
    if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || !ts.ends_with('Z') {
        return None;
    }
    let num = |a: usize, z: usize| ts.get(a..z)?.parse::<i64>().ok();
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi, s) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) {
        return None;
    }
    if !(0..=23).contains(&h) || !(0..=59).contains(&mi) || !(0..=60).contains(&s) {
        return None;
    }
    // Optional fraction between the seconds and the trailing Z.
    let frac = &ts[19..ts.len() - 1];
    let micros: i64 = if frac.is_empty() {
        0
    } else {
        let digits = frac.strip_prefix('.')?;
        if digits.is_empty() || !digits.bytes().all(|c| c.is_ascii_digit()) {
            return None;
        }
        let mut padded: String = digits.chars().take(6).collect();
        while padded.len() < 6 {
            padded.push('0');
        }
        padded.parse::<i64>().ok()?
    };
    // Days from civil epoch (Howard Hinnant's algorithm).
    let y2 = if mo <= 2 { y - 1 } else { y };
    let era = if y2 >= 0 { y2 } else { y2 - 399 } / 400;
    let yoe = y2 - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let secs = days * 86_400 + h * 3600 + mi * 60 + s;
    let us = u64::try_from(secs).ok()?.checked_mul(1_000_000)?;
    us.checked_add(u64::try_from(micros).ok()?)
}

/// A "user" message the harness injected rather than the person typed:
/// wrapped in a tag (`<system-reminder>`, `<recommended_plugins>`,
/// `<environment_context>`, `<task-notification>` and friends), the
/// `# Files mentioned by the user` attachment, an interruption notice, or
/// an `[Image: ...]` placeholder standing in for a picture.
///
/// Three tags wrap things the person did type or paste and are kept:
/// `<dictation>`, `<pasted_content>` and `<email ...>`.
#[must_use]
pub fn is_injected_user_text(body: &str) -> bool {
    let s = body.trim_start();
    if USER_AUTHORED_TAGS.iter().any(|tag| s.starts_with(tag)) {
        return false;
    }
    s.starts_with('<')
        || s.starts_with("# Files mentioned by the user")
        || s.starts_with("[Request interrupted")
        || s.starts_with("[Image:")
}

/// Tag prefixes that wrap text the person authored (spoken, pasted, or an
/// email they handed over), so the leading `<` does not mean "injected".
const USER_AUTHORED_TAGS: [&str; 3] = ["<dictation", "<pasted_content", "<email"];

/// Collapse runs of whitespace (newlines included) to one space and cut at
/// [`TOOL_LINE_MAX_CHARS`] characters, so one tool line stays one line.
#[must_use]
pub fn tool_line(tool: &str, primary_arg: &str) -> String {
    let arg = primary_arg.split_whitespace().collect::<Vec<_>>().join(" ");
    let line = if arg.is_empty() {
        tool.to_string()
    } else {
        format!("{tool} {arg}")
    };
    line.chars().take(TOOL_LINE_MAX_CHARS).collect()
}

const GIT_MUTATING_VERBS: [&str; 8] = [
    "commit", "push", "checkout", "switch", "merge", "rebase", "tag", "stash",
];

/// Whether a shell command mutates the repository or publishes something.
///
/// The command is cut into segments at `&&`, `||`, `;`, `|` and newlines,
/// and each segment is judged on its first tokens: `git commit|push|
/// checkout|switch|merge|rebase|tag|stash` (global `-C dir` and `-c k=v`
/// options are stepped over), `gh pr ...`, `npm publish`, `cargo publish`,
/// or `vercel`. A leading `cd x`, `env`, `sudo` or `VAR=value` does not
/// hide the verb, and a `bash -lc '...'` wrapper is unwrapped. Reads,
/// greps, builds and tests are not mutating.
#[must_use]
pub fn is_mutating_shell(command: &str) -> bool {
    split_shell_segments(command)
        .iter()
        .any(|segment| segment_is_mutating(segment))
}

fn split_shell_segments(command: &str) -> Vec<String> {
    let mut segments = Vec::new();
    let mut current = String::new();
    let mut chars = command.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '&' | '|' if chars.peek() == Some(&c) => {
                chars.next();
                segments.push(std::mem::take(&mut current));
            }
            '|' | ';' | '\n' => segments.push(std::mem::take(&mut current)),
            _ => current.push(c),
        }
    }
    segments.push(current);
    segments
        .into_iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

fn segment_is_mutating(segment: &str) -> bool {
    let tokens: Vec<&str> = segment.split_whitespace().collect();
    let mut i = 0;
    // Step over prefixes that do not change what runs.
    while i < tokens.len() {
        let t = tokens[i];
        let is_assignment = t.contains('=') && !t.starts_with('-') && !t.starts_with('=');
        if is_assignment || matches!(t, "env" | "sudo" | "nohup" | "time" | "exec") {
            i += 1;
        } else {
            break;
        }
    }
    let Some(&first) = tokens.get(i) else {
        return false;
    };
    let first = first.trim_matches(|c| c == '"' || c == '\'');
    match first {
        "bash" | "sh" | "zsh" => {
            // `bash -lc "<script>"`: judge the script.
            let Some(flag) = tokens.get(i + 1) else {
                return false;
            };
            if !flag.starts_with('-') || !flag.contains('c') {
                return false;
            }
            let script = tokens[i + 2..].join(" ");
            let script = script.trim_matches(|c| c == '"' || c == '\'' || c == '`');
            is_mutating_shell(script)
        }
        "git" => {
            let mut j = i + 1;
            while let Some(t) = tokens.get(j) {
                if t.starts_with('-') {
                    // `-C <dir>` and `-c <k=v>` take a value; long options
                    // carry theirs after `=`.
                    if matches!(*t, "-C" | "-c") {
                        j += 1;
                    }
                    j += 1;
                } else {
                    break;
                }
            }
            tokens
                .get(j)
                .is_some_and(|verb| GIT_MUTATING_VERBS.contains(verb))
        }
        "gh" => tokens.get(i + 1) == Some(&"pr"),
        "npm" | "cargo" => tokens.get(i + 1) == Some(&"publish"),
        "vercel" => true,
        _ => false,
    }
}

/// How a file should be read given its stored cursor and current state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadPlan {
    /// Size and mtime match the cursor: nothing new, do not open it.
    Unchanged,
    /// Continue from the cursor's byte offset and line count.
    Resume(ImportCursor),
    /// Read from the start. `rewound` is true when a cursor existed but
    /// the file shrank, so it was rewritten and may repeat old lines.
    FromStart {
        /// A cursor existed and the file is smaller than it recorded.
        rewound: bool,
    },
}

/// Decide how to read a file.
#[must_use]
pub fn plan_read(cursor: Option<ImportCursor>, file_size: u64, mtime_us: u64) -> ReadPlan {
    match cursor {
        None => ReadPlan::FromStart { rewound: false },
        Some(c) if file_size < c.file_size || file_size < c.byte_offset => {
            ReadPlan::FromStart { rewound: true }
        }
        Some(c) if file_size == c.file_size && mtime_us == c.mtime_us => ReadPlan::Unchanged,
        Some(c) => ReadPlan::Resume(c),
    }
}

/// Size and mtime (microseconds since epoch) of a file.
///
/// # Errors
/// Whatever `std::fs::metadata` reports.
pub fn file_state(path: &Path) -> std::io::Result<(u64, u64)> {
    let meta = std::fs::metadata(path)?;
    let mtime_us = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map_or(0, |d| u64::try_from(d.as_micros()).unwrap_or(u64::MAX));
    Ok((meta.len(), mtime_us))
}

/// Read the first line of a file, without its newline. Empty if the file
/// is empty. Used to re-establish per-file state (Codex `session_meta`)
/// when resuming past the start.
///
/// # Errors
/// Whatever opening or reading the file reports.
pub fn read_first_line(path: &Path) -> std::io::Result<String> {
    use std::io::BufRead;
    let file = std::fs::File::open(path)?;
    let mut reader = std::io::BufReader::new(file);
    let mut buf = Vec::new();
    reader.read_until(b'\n', &mut buf)?;
    if buf.last() == Some(&b'\n') {
        buf.pop();
    }
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

/// Why the per-line loop stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileOutcome {
    /// The file was not opened because the cursor said it is unchanged.
    Unchanged,
    /// Every complete line was consumed.
    Done,
    /// The deadline passed; the cursor points at the next unread line.
    Deadline,
}

/// Read one transcript file incrementally, handing each complete line to
/// `handle_line(line_no, line, stats)`, and store its cursor afterwards.
///
/// `handle_line` returns `Ok(true)` to keep going and `Ok(false)` to stop
/// reading this file for good (the importer decided it is not wanted, for
/// example a Codex subagent thread); the cursor is then parked at the end
/// so the file is not re-parsed until it changes.
///
/// # Errors
/// [`ImportError::Store`] from `handle_line` or from storing the cursor.
/// I/O errors on the file itself are not fatal to the pass: the file is
/// skipped and left for the next run.
pub fn import_file<F>(
    store: &SqlCipherBrainStore,
    path: &Path,
    deadline: Option<Instant>,
    stats: &mut ImportStats,
    mut handle_line: F,
) -> Result<FileOutcome, ImportError>
where
    F: FnMut(u64, &str, &mut ImportStats) -> Result<bool, ImportError>,
{
    let path_str = path.to_string_lossy();
    let Ok((file_size, mtime_us)) = file_state(path) else {
        return Ok(FileOutcome::Done);
    };
    let cursor = store
        .get_import_cursor(&path_str)
        .map_err(|e| ImportError::Store(e.to_string()))?;

    let (start_offset, start_line) = match plan_read(cursor, file_size, mtime_us) {
        ReadPlan::Unchanged => {
            stats.files_unchanged += 1;
            return Ok(FileOutcome::Unchanged);
        }
        ReadPlan::Resume(c) => {
            stats.files_resumed += 1;
            (c.byte_offset, c.line_no)
        }
        ReadPlan::FromStart { rewound } => {
            if rewound {
                stats.files_rewound += 1;
                eprintln!(
                    "mci-agent import: {} shrank since its last import; re-reading from the start \
                     (some events may repeat)",
                    path.display()
                );
            }
            (0, 0)
        }
    };

    let Ok(mut file) = std::fs::File::open(path) else {
        return Ok(FileOutcome::Done);
    };
    if start_offset > 0 && file.seek(SeekFrom::Start(start_offset)).is_err() {
        return Ok(FileOutcome::Done);
    }
    stats.files_scanned += 1;

    // Streamed one line at a time: a rollout can be hundreds of megabytes,
    // and this runs inside a session-start hook.
    let mut reader = BufReader::with_capacity(1 << 16, file);
    let mut buf: Vec<u8> = Vec::new();
    let mut consumed: u64 = 0;
    let mut line_no = start_line;
    let mut outcome = FileOutcome::Done;
    let mut wanted = true;
    let mut since_check: u64 = 0;

    loop {
        buf.clear();
        let n = match reader.read_until(b'\n', &mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        stats.bytes_read += n as u64;
        let complete = buf.last() == Some(&b'\n');
        let line_bytes = if complete { &buf[..n - 1] } else { &buf[..] };
        let line = String::from_utf8_lossy(line_bytes);
        let line = line.trim_end_matches('\r');
        if !complete {
            // No newline yet: a record still being written, unless it
            // already parses, in which case the writer just has not
            // flushed the newline and the record is whole.
            if serde_json::from_str::<serde::de::IgnoredAny>(line).is_err() {
                break;
            }
        }
        line_no += 1;
        consumed += n as u64;
        if wanted && !line.trim().is_empty() {
            wanted = handle_line(line_no, line, stats)?;
        }
        since_check += 1;
        if since_check >= DEADLINE_CHECK_EVERY {
            since_check = 0;
            if deadline.is_some_and(|d| Instant::now() >= d) {
                outcome = FileOutcome::Deadline;
                stats.deadline_hit = true;
                break;
            }
        }
    }

    let (byte_offset, line_no) = if wanted {
        (start_offset + consumed, line_no)
    } else {
        // Not wanted: park at the end so it is only looked at again when
        // it changes. Line count is then not meaningful; keep what we had.
        (file_size, line_no)
    };
    store
        .set_import_cursor(
            &path_str,
            &ImportCursor {
                byte_offset,
                file_size,
                mtime_us,
                line_no,
                updated_at_us: 0,
            },
        )
        .map_err(|e| ImportError::Store(e.to_string()))?;
    Ok(outcome)
}

/// Import a whole root by handing each file to `import_one`, stopping at
/// the deadline. `files` must already be sorted for reproducible passes.
///
/// # Errors
/// The first [`ImportError`] an importer returns.
pub fn import_files<F>(
    files: &[std::path::PathBuf],
    deadline: Option<Instant>,
    stats: &mut ImportStats,
    mut import_one: F,
) -> Result<(), ImportError>
where
    F: FnMut(&Path, &mut ImportStats) -> Result<FileOutcome, ImportError>,
{
    for path in files {
        if deadline.is_some_and(|d| Instant::now() >= d) {
            stats.deadline_hit = true;
            return Ok(());
        }
        if import_one(path, stats)? == FileOutcome::Deadline {
            return Ok(());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps_parse_to_microseconds() {
        // 2024-01-01T00:00:00Z = 1_704_067_200 s
        assert_eq!(
            parse_ts_us("2024-01-01T00:00:00.000Z"),
            Some(1_704_067_200_000_000)
        );
        assert_eq!(parse_ts_us("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            parse_ts_us("2026-09-11T23:28:41.225Z"),
            Some(1_789_169_321_225_000)
        );
    }

    #[test]
    fn malformed_timestamps_are_rejected_not_guessed() {
        assert_eq!(parse_ts_us(""), None);
        assert_eq!(parse_ts_us("not-a-date"), None);
        assert_eq!(parse_ts_us("2024-13-01T00:00:00Z"), None, "month 13");
        assert_eq!(parse_ts_us("2024-01-32T00:00:00Z"), None, "day 32");
        assert_eq!(parse_ts_us("2024-01-01T25:00:00Z"), None, "hour 25");
        assert_eq!(parse_ts_us("2024-01-01T00:00:00.abcZ"), None, "fraction");
    }

    #[test]
    fn header_matches_the_contract_exactly() {
        let ctx = EventContext {
            agent: Agent::ClaudeCode,
            label: "hippocampus",
            cwd: "/Users/amy/hippocampus",
            branch: "main",
            session: "abc-123",
            src_path: "/Users/amy/.claude/projects/-Users-amy-hippocampus/abc-123.jsonl",
            line_no: 17,
        };
        assert_eq!(
            ctx.header(Role::User),
            "[app=claude-code | title=hippocampus · user | url=/Users/amy/hippocampus#main | \
             session=abc-123 | src=/Users/amy/.claude/projects/-Users-amy-hippocampus/abc-123.jsonl:17]"
        );
        let codex = EventContext {
            agent: Agent::Codex,
            branch: "",
            ..ctx
        };
        assert!(codex
            .header(Role::Tool)
            .starts_with("[app=codex | title=hippocampus · tool | url=/Users/amy/hippocampus# | "));
    }

    #[test]
    fn injected_user_text_is_recognized() {
        assert!(is_injected_user_text("<system-reminder>\nhi"));
        assert!(is_injected_user_text("  <recommended_plugins>"));
        assert!(is_injected_user_text(
            "# Files mentioned by the user\n- a.rs"
        ));
        assert!(is_injected_user_text("[Request interrupted by user]"));
        assert!(is_injected_user_text("[Image: source: /private/tmp/x.png]"));
        assert!(!is_injected_user_text("please fix the bug in <main>"));
        assert!(!is_injected_user_text("# Plan\n1. do x"));
        assert!(!is_injected_user_text(
            "[Image] is a caption the user typed"
        ));
    }

    #[test]
    fn user_authored_wrappers_are_kept() {
        assert!(!is_injected_user_text(
            "<dictation>ship it tonight</dictation>"
        ));
        assert!(!is_injected_user_text(
            "<pasted_content id=\"cfef\">\nfoo\n</pasted_content>"
        ));
        assert!(!is_injected_user_text(
            "<email from=\"dana@example.com\" subject=\"x\">hi</email>"
        ));
        // The allowlist is prefix-based on the tag name, not any tag
        // starting with those letters plus a bare `<`.
        assert!(is_injected_user_text("<environment_context>"));
    }

    #[test]
    fn mutating_shell_detection() {
        for yes in [
            "git commit -m 'x'",
            "cd /a/b && git add . && git commit -m \"feat: y\"",
            "git -C /repo push origin main",
            "git -c user.name=x commit -m z",
            "gh pr create --title t",
            "npm publish",
            "cargo publish --dry-run",
            "vercel --prod",
            "bash -lc \"git checkout -b feat/x\"",
            "FOO=1 git stash push -m x",
            "git status; git tag v1",
            "git log | head\ngit merge main",
        ] {
            assert!(is_mutating_shell(yes), "{yes}");
        }
        for no in [
            "git status --short",
            "git log --oneline -5",
            "git diff | head",
            "ls -la && cat x",
            "cargo build -p mci-agent",
            "grep -rn 'git commit' src/",
            "gh api repos/x/y",
            "npm install",
            "",
        ] {
            assert!(!is_mutating_shell(no), "{no}");
        }
    }

    #[test]
    fn tool_lines_are_one_line_and_bounded() {
        let long = "x".repeat(500);
        let line = tool_line("Bash", &format!("git commit -m\n\"{long}\""));
        assert_eq!(line.chars().count(), TOOL_LINE_MAX_CHARS);
        assert!(!line.contains('\n'));
        assert!(line.starts_with("Bash git commit -m \"xxx"));
        assert_eq!(tool_line("Edit", "/a/b.rs"), "Edit /a/b.rs");
    }

    #[test]
    fn read_plans_follow_the_cursor_rules() {
        let c = ImportCursor {
            byte_offset: 100,
            file_size: 100,
            mtime_us: 5,
            line_no: 3,
            updated_at_us: 0,
        };
        assert_eq!(
            plan_read(None, 10, 1),
            ReadPlan::FromStart { rewound: false }
        );
        assert_eq!(plan_read(Some(c), 100, 5), ReadPlan::Unchanged);
        assert_eq!(plan_read(Some(c), 150, 6), ReadPlan::Resume(c));
        assert_eq!(
            plan_read(Some(c), 100, 6),
            ReadPlan::Resume(c),
            "touched, same size"
        );
        assert_eq!(
            plan_read(Some(c), 40, 6),
            ReadPlan::FromStart { rewound: true }
        );
    }

    #[test]
    fn basename_takes_the_last_component() {
        assert_eq!(basename("/Users/amy/hippo-work"), "hippo-work");
        assert_eq!(basename("/Users/amy/hippo-work/"), "hippo-work");
        assert_eq!(basename(""), "");
    }
}
