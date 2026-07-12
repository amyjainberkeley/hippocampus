//! FSEvents-backed watcher for `chat.db` activity.
//!
//! Messages.app writes the WAL on every received message — the `SQLite`
//! file at `~/Library/Messages/chat.db` is touched, plus the
//! `chat.db-wal` and `chat.db-shm` companions. We watch the containing
//! directory non-recursively and emit a [`NewMessageEvent`] whenever any
//! of those three files is touched.
//!
//! V2-P7 keeps the watcher minimal — no debouncer, no per-row delta
//! detection. The cascade-equivalent in `core/brain/src/redaction/
//! messages_plugin.rs` is responsible for diff-detection on the
//! producer side (poll `list_recent_messages` since the last watermark
//! whenever the watcher fires). V2-P10/11 layers any additional
//! debouncing on top.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use notify::event::{CreateKind, DataChange, EventKind, ModifyKind};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use tokio::sync::mpsc;

use crate::discover::ChatDbLocation;
use crate::error::MessagesReaderError;

/// `chat.db` (or its WAL / shm) was touched. The caller re-polls
/// [`crate::list_recent_messages`] with its watermark to surface the
/// actual new rows.
#[derive(Debug, Clone)]
pub struct NewMessageEvent {
    /// Absolute path to the file `FSEvents` reported on. Useful for
    /// debugging; the cascade-equivalent does not key off it.
    pub path: PathBuf,
}

/// Live watcher handle.
///
/// Drop the handle to stop the `FSEvents` stream; the inner
/// `RecommendedWatcher` cleans up on drop. The receiver returns `None`
/// when the watcher is dropped, mirroring the `tokio::sync::mpsc` shape.
pub struct InboxWatcher {
    rx: mpsc::Receiver<NewMessageEvent>,
    _watcher: RecommendedWatcher,
}

impl InboxWatcher {
    /// Async-await the next [`NewMessageEvent`]. Returns `None` only if
    /// the `FSEvents` stream is gone (currently: never, in practice — the
    /// stream is bound to the watcher's lifetime).
    pub async fn next(&mut self) -> Option<NewMessageEvent> {
        self.rx.recv().await
    }

    /// Non-blocking recv. Used by tests where waiting forever is the
    /// wrong shape and we already know an event should be present.
    pub fn try_next(&mut self) -> Option<NewMessageEvent> {
        self.rx.try_recv().ok()
    }
}

/// Start a non-recursive `FSEvents` watch over the discovered
/// `~/Library/Messages/` directory and return a receiver that fires
/// once per WAL touch.
///
/// `channel_capacity` bounds the mpsc; 64 is plenty — the
/// cascade-equivalent drains the channel as fast as Messages.app drops
/// new rows. Backpressure is acceptable because the watcher's signal is
/// "go re-poll", not "ingest these N rows" — a dropped event still
/// leaves the source-of-truth on disk.
pub fn watch_inbox(
    loc: &ChatDbLocation,
    channel_capacity: usize,
) -> Result<InboxWatcher, MessagesReaderError> {
    watch_path(&loc.root, channel_capacity)
}

/// Watch an arbitrary directory tree. Exposed as a separate entry point
/// so tests can target a tempdir without synthesizing a
/// [`ChatDbLocation`].
pub fn watch_path(
    root: &Path,
    channel_capacity: usize,
) -> Result<InboxWatcher, MessagesReaderError> {
    let (tx, rx) = mpsc::channel(channel_capacity.max(1));
    let tx = Arc::new(tx);

    let tx_inner = Arc::clone(&tx);
    let mut watcher = RecommendedWatcher::new(
        move |result: notify::Result<notify::Event>| {
            let Ok(event) = result else { return };
            if !is_chat_db_touch(event.kind) {
                return;
            }
            for path in event.paths {
                let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
                if name == "chat.db" || name == "chat.db-wal" || name == "chat.db-shm" {
                    let ev = NewMessageEvent { path };
                    // `try_send` keeps the `FSEvents` callback non-blocking.
                    // A full mpsc means the consumer is behind; the event
                    // is dropped but the rows are on disk and will be
                    // picked up by the next `list_recent_messages` poll.
                    let _ = tx_inner.try_send(ev);
                }
            }
        },
        notify::Config::default(),
    )
    .map_err(|e| MessagesReaderError::Watcher {
        path: root.to_path_buf(),
        source: e,
    })?;

    // Non-recursive — `~/Library/Messages/` contains the three SQLite
    // files at the top level, plus a `Attachments/` subdirectory which
    // V2-P7 deliberately does NOT walk into (CSO §5 protected-set:
    // attachment content is out-of-scope for the read path).
    watcher
        .watch(root, RecursiveMode::NonRecursive)
        .map_err(|e| MessagesReaderError::Watcher {
            path: root.to_path_buf(),
            source: e,
        })?;

    Ok(InboxWatcher {
        rx,
        _watcher: watcher,
    })
}

/// Treat any create / modify on the three chat.db `SQLite` files as a
/// "Messages.app touched the WAL" signal.
fn is_chat_db_touch(kind: EventKind) -> bool {
    matches!(
        kind,
        EventKind::Create(CreateKind::File | CreateKind::Any)
            | EventKind::Modify(
                ModifyKind::Data(DataChange::Any | DataChange::Content | DataChange::Size)
                    | ModifyKind::Any
            )
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::Duration;
    use tempfile::tempdir;

    #[tokio::test(flavor = "current_thread")]
    async fn emits_event_on_chat_db_touch() {
        let tmp = tempdir().unwrap();
        let root = tmp.path();

        let mut w = watch_path(root, 16).expect("watch ok");

        // FSEvents has nontrivial setup latency on a cold runner.
        tokio::time::sleep(Duration::from_millis(300)).await;

        let target = root.join("chat.db");
        fs::write(&target, b"SQLite format 3\0").unwrap();

        let mut got = None;
        for _ in 0..50 {
            if let Ok(ev) = tokio::time::timeout(Duration::from_millis(100), w.next()).await {
                got = ev;
                if got.is_some() {
                    break;
                }
            }
        }
        let ev = got.expect("watcher should fire for chat.db touch");
        assert!(ev.path.ends_with("chat.db"));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn ignores_unrelated_files() {
        let tmp = tempdir().unwrap();
        let mut w = watch_path(tmp.path(), 16).expect("watch ok");
        tokio::time::sleep(Duration::from_millis(300)).await;
        fs::write(tmp.path().join("README.md"), b"x").unwrap();
        let res = tokio::time::timeout(Duration::from_millis(500), w.next()).await;
        match res {
            Err(_) | Ok(None) => {}
            Ok(Some(ev)) => panic!("should not have emitted: {ev:?}"),
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn emits_for_chat_db_wal() {
        let tmp = tempdir().unwrap();
        let mut w = watch_path(tmp.path(), 16).expect("watch ok");
        tokio::time::sleep(Duration::from_millis(300)).await;

        fs::write(tmp.path().join("chat.db-wal"), b"WAL").unwrap();

        let mut got = None;
        for _ in 0..50 {
            if let Ok(ev) = tokio::time::timeout(Duration::from_millis(100), w.next()).await {
                got = ev;
                if got.is_some() {
                    break;
                }
            }
        }
        let ev = got.expect("watcher should fire for WAL touch");
        assert!(ev.path.ends_with("chat.db-wal"));
    }
}
