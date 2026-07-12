//! FSEvents-backed watcher for new `.emlx` files.
//!
//! Per Mail-spike memo §7: watch the account root recursively, emit a
//! [`NewMessageEvent`] whenever a `.emlx` file is created (or renamed
//! into the tree from the IMAP fetcher's temporary holding dir).
//!
//! V2-P8a keeps this minimal — no debouncer, no `V<N>` re-bind logic.
//! V2-P8b layers debouncing + WAL-tail correlation on top.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use notify::event::{CreateKind, EventKind, ModifyKind, RenameMode};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use tokio::sync::mpsc;

use crate::discover::MailAccount;
use crate::error::MailReaderError;

/// A new `.emlx` file has appeared inside the watched account root.
#[derive(Debug, Clone)]
pub struct NewMessageEvent {
    /// Absolute path to the new emlx file. Callers pass this to
    /// [`crate::read_message`] to materialize a [`crate::ParsedMessage`].
    pub path: PathBuf,
}

/// Live watcher handle.
///
/// Drop the handle to stop the `FSEvents` stream; the inner
/// `RecommendedWatcher` cleans up on drop. The receiver returns `None`
/// when the watcher is dropped, mirroring the `tokio::sync::mpsc` shape.
pub struct InboxWatcher {
    rx: mpsc::Receiver<NewMessageEvent>,
    // Holds the FSEvents stream alive for the lifetime of `InboxWatcher`.
    _watcher: RecommendedWatcher,
}

impl InboxWatcher {
    /// Async-await the next [`NewMessageEvent`]. Returns `None` only if
    /// the `FSEvents` stream is gone (currently: never, in practice — the
    /// stream is bound to the watcher's lifetime).
    pub async fn next(&mut self) -> Option<NewMessageEvent> {
        self.rx.recv().await
    }

    /// Non-blocking recv, used by tests where waiting forever is the wrong
    /// shape and we already know an event should be present.
    pub fn try_next(&mut self) -> Option<NewMessageEvent> {
        self.rx.try_recv().ok()
    }
}

/// Start a recursive `FSEvents` watch over `account.root` and return a
/// receiver that fires once per new `.emlx` file.
///
/// `channel_capacity` bounds the mpsc; a small value (e.g. 64) is fine —
/// the cascade-equivalent in V2-P8b drains it as fast as Mail.app drops
/// new emlx. Backpressure is acceptable here because we always re-read
/// from disk via `read_message(path)`, so no data is lost on a drop.
pub fn watch_inbox(
    account: &MailAccount,
    channel_capacity: usize,
) -> Result<InboxWatcher, MailReaderError> {
    watch_path(&account.root, channel_capacity)
}

/// Watch an arbitrary directory tree. Exposed as a separate entry point so
/// tests can target a tempdir without synthesizing a `MailAccount`.
pub fn watch_path(root: &Path, channel_capacity: usize) -> Result<InboxWatcher, MailReaderError> {
    let (tx, rx) = mpsc::channel(channel_capacity.max(1));
    let tx = Arc::new(tx);

    let tx_inner = Arc::clone(&tx);
    let mut watcher = RecommendedWatcher::new(
        move |result: notify::Result<notify::Event>| {
            let Ok(event) = result else { return };
            if !is_emlx_appearance(event.kind) {
                return;
            }
            for path in event.paths {
                if path.extension().and_then(|s| s.to_str()) == Some("emlx") {
                    let ev = NewMessageEvent { path };
                    // `try_send` keeps the FSEvents callback non-blocking.
                    // A full mpsc means the consumer is behind; the event
                    // is dropped but the file is on disk and will be
                    // picked up by the next `list_recent_messages` poll.
                    let _ = tx_inner.try_send(ev);
                }
            }
        },
        notify::Config::default(),
    )
    .map_err(|e| MailReaderError::Watcher {
        path: root.to_path_buf(),
        source: e,
    })?;

    watcher
        .watch(root, RecursiveMode::Recursive)
        .map_err(|e| MailReaderError::Watcher {
            path: root.to_path_buf(),
            source: e,
        })?;

    Ok(InboxWatcher {
        rx,
        _watcher: watcher,
    })
}

/// Treat both `Create::File` and `Modify::Name(To)` (rename-in) as
/// "an emlx file appeared at this path".
///
/// Mail.app's IMAP fetcher writes to a `*.partial.emlx`-ish temp and
/// renames into place, so the rename arrives as `Modify::Name(To)` on
/// `FSEvents`. Catching both shapes makes the watcher robust without
/// needing a separate "rename tracking" data structure.
fn is_emlx_appearance(kind: EventKind) -> bool {
    matches!(
        kind,
        EventKind::Create(CreateKind::File | CreateKind::Any)
            | EventKind::Modify(ModifyKind::Name(RenameMode::To | RenameMode::Any))
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::Duration;
    use tempfile::tempdir;

    #[tokio::test(flavor = "current_thread")]
    async fn emits_event_on_new_emlx() {
        let tmp = tempdir().unwrap();
        let sub = tmp
            .path()
            .join("INBOX.mbox")
            .join("UUID")
            .join("Data")
            .join("Messages");
        fs::create_dir_all(&sub).unwrap();

        let mut w = watch_path(tmp.path(), 16).expect("watch ok");

        let target = sub.join("1.emlx");
        // FSEvents has nontrivial setup latency; small sleep before write
        // is needed in the test environment. The runtime is single-threaded
        // tokio so we use tokio::time::sleep.
        tokio::time::sleep(Duration::from_millis(300)).await;
        fs::write(&target, b"          \nx").unwrap();

        // Poll for up to ~5s for the event to surface. macOS FSEvents
        // latency on CI is sub-second in steady state but can spike on a
        // cold runner.
        let mut got = None;
        for _ in 0..50 {
            if let Ok(ev) = tokio::time::timeout(Duration::from_millis(100), w.next()).await {
                got = ev;
                if got.is_some() {
                    break;
                }
            }
        }
        let ev = got.expect("FSEvents should fire for the new emlx file");
        assert!(ev.path.ends_with("1.emlx"));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn ignores_non_emlx_files() {
        let tmp = tempdir().unwrap();
        let mut w = watch_path(tmp.path(), 16).expect("watch ok");
        tokio::time::sleep(Duration::from_millis(300)).await;
        fs::write(tmp.path().join("notmail.txt"), b"x").unwrap();
        let res = tokio::time::timeout(Duration::from_millis(500), w.next()).await;
        // Either timeout or no event surfaced — neither should be Some(_).
        match res {
            Err(_) | Ok(None) => {}
            Ok(Some(ev)) => panic!("should not have emitted: {ev:?}"),
        }
    }
}
