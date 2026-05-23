//! Page-content listener and URL→text cache for the browser extension
//! pipeline (Phase 7 pull-forward).
//!
//! The native messaging host (`hippocampus-native-host`) writes
//! `PageContentEvent` wire frames to a UNIX domain socket at
//! `~/Library/Application Support/MCI/page_content.sock`. This module
//! provides:
//!
//! - [`PageContentCache`]: an in-memory URL → full_text cache with a
//!   configurable TTL (default 5 s). The agent's runner checks this
//!   cache when processing `OCREvent` frames from the helper — if a
//!   cached PageContentEvent exists for the same URL, the extension's
//!   full text is preferred over pixel-OCR text.
//!
//! - [`PageContentListener`]: accepts connections on the UNIX socket
//!   and reads `PageContentEvent` wire frames, forwarding them to the
//!   brain ingestor and populating the cache.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use mci_core::ipc::reader::FrameReader;
use mci_core::ipc::Message;
use tokio::net::UnixListener;

use crate::brain_ingest::{BrainIngestor, IngestOutcome};

const DEFAULT_TTL: Duration = Duration::from_secs(5);

#[derive(Debug, Clone)]
struct CacheEntry {
    text: String,
    title: String,
    source_browser: String,
    inserted: Instant,
}

/// URL → full page text cache with configurable TTL. Thread-safe;
/// shared across the runner and page-content listener tasks.
#[derive(Debug, Clone)]
pub struct PageContentCache {
    inner: Arc<Mutex<HashMap<String, CacheEntry>>>,
    ttl: Duration,
}

/// A cache hit returned by [`PageContentCache::get`].
#[derive(Debug, Clone)]
pub struct CachedPageContent {
    /// Full page text from the extension.
    pub text: String,
    /// Page title from the extension.
    pub title: String,
    /// Source browser identifier.
    pub source_browser: String,
}

impl PageContentCache {
    /// Create a new cache with the default 5-second TTL.
    #[must_use]
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(HashMap::new())),
            ttl: DEFAULT_TTL,
        }
    }

    /// Create a new cache with a custom TTL.
    #[must_use]
    pub fn with_ttl(ttl: Duration) -> Self {
        Self {
            inner: Arc::new(Mutex::new(HashMap::new())),
            ttl,
        }
    }

    /// Insert or update page content for a URL.
    pub fn insert(&self, url: String, text: String, title: String, source_browser: String) {
        let mut map = self.inner.lock().expect("cache lock");
        map.insert(
            url,
            CacheEntry {
                text,
                title,
                source_browser,
                inserted: Instant::now(),
            },
        );
    }

    /// Look up cached page content for a URL. Returns `None` if absent or expired.
    pub fn get(&self, url: &str) -> Option<CachedPageContent> {
        let map = self.inner.lock().expect("cache lock");
        let entry = map.get(url)?;
        if entry.inserted.elapsed() > self.ttl {
            return None;
        }
        Some(CachedPageContent {
            text: entry.text.clone(),
            title: entry.title.clone(),
            source_browser: entry.source_browser.clone(),
        })
    }

    /// Remove all entries whose TTL has elapsed.
    pub fn evict_expired(&self) {
        let mut map = self.inner.lock().expect("cache lock");
        map.retain(|_, v| v.inserted.elapsed() <= self.ttl);
    }

    /// Number of entries (including potentially expired ones).
    #[must_use]
    pub fn len(&self) -> usize {
        self.inner.lock().expect("cache lock").len()
    }
}

impl Default for PageContentCache {
    fn default() -> Self {
        Self::new()
    }
}

/// Accepts connections on a UNIX domain socket and reads `PageContentEvent`
/// wire frames, forwarding them to the brain ingestor.
///
/// Both the Chromium native messaging host and the Safari container-app
/// inbox reader connect to this socket to deliver page content events.
pub struct PageContentListener {
    sock_path: PathBuf,
    frames_ingested: AtomicU64,
}

impl PageContentListener {
    /// Create a new listener bound to `sock_path`. Removes any stale socket
    /// file left by a prior run.
    ///
    /// # Errors
    /// Returns an IO error if the socket cannot be bound.
    pub fn bind(sock_path: &Path) -> std::io::Result<(Self, UnixListener)> {
        let _ = std::fs::remove_file(sock_path);
        if let Some(parent) = sock_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let listener = UnixListener::bind(sock_path)?;
        Ok((
            Self {
                sock_path: sock_path.to_owned(),
                frames_ingested: AtomicU64::new(0),
            },
            listener,
        ))
    }

    /// Number of frames successfully ingested across all connections.
    #[must_use]
    pub fn frames_ingested(&self) -> u64 {
        self.frames_ingested.load(Ordering::Relaxed)
    }

    /// Accept connections in a loop and feed frames to `brain`. Runs until
    /// the listener is dropped or the task is cancelled.
    pub async fn run(&self, listener: UnixListener, brain: Arc<dyn BrainIngestor>) {
        loop {
            let (stream, _) = match listener.accept().await {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("page-content-listener: accept error: {e}");
                    continue;
                }
            };
            let brain = Arc::clone(&brain);
            let counter = &self.frames_ingested;
            let mut reader = FrameReader::new();
            let mut stream = stream;
            loop {
                match reader.read_frame(&mut stream).await {
                    Ok(Some(frame)) => {
                        if matches!(frame.message, Message::PageContentEvent { .. }) {
                            match brain.ingest_ocr_event(&frame.message) {
                                Ok(IngestOutcome::Stored { .. }) => {
                                    counter.fetch_add(1, Ordering::Relaxed);
                                }
                                Ok(IngestOutcome::NotOcrEvent) => {}
                                Err(e) => {
                                    eprintln!("page-content-listener: ingest error: {e}");
                                }
                            }
                        }
                    }
                    Ok(None) => break,
                    Err(e) => {
                        eprintln!("page-content-listener: read error: {e}");
                        break;
                    }
                }
            }
        }
    }

    /// Socket path this listener is bound to.
    #[must_use]
    pub fn sock_path(&self) -> &Path {
        &self.sock_path
    }
}

impl Drop for PageContentListener {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.sock_path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_and_get() {
        let cache = PageContentCache::new();
        cache.insert(
            "https://example.com".into(),
            "full text".into(),
            "Example".into(),
            "chrome".into(),
        );
        let hit = cache.get("https://example.com").unwrap();
        assert_eq!(hit.text, "full text");
        assert_eq!(hit.title, "Example");
        assert_eq!(hit.source_browser, "chrome");
    }

    #[test]
    fn miss_on_unknown_url() {
        let cache = PageContentCache::new();
        assert!(cache.get("https://unknown.com").is_none());
    }

    #[test]
    fn expired_entry_returns_none() {
        let cache = PageContentCache::with_ttl(Duration::from_millis(1));
        cache.insert(
            "https://example.com".into(),
            "text".into(),
            "t".into(),
            "chrome".into(),
        );
        std::thread::sleep(Duration::from_millis(5));
        assert!(cache.get("https://example.com").is_none());
    }

    #[test]
    fn evict_expired_cleans_stale() {
        let cache = PageContentCache::with_ttl(Duration::from_millis(1));
        cache.insert("a".into(), "1".into(), "t".into(), "c".into());
        cache.insert("b".into(), "2".into(), "t".into(), "c".into());
        std::thread::sleep(Duration::from_millis(5));
        cache.evict_expired();
        assert_eq!(cache.len(), 0);
    }

    #[test]
    fn overwrite_same_url() {
        let cache = PageContentCache::new();
        cache.insert("u".into(), "old".into(), "t".into(), "c".into());
        cache.insert("u".into(), "new".into(), "t".into(), "c".into());
        assert_eq!(cache.get("u").unwrap().text, "new");
        assert_eq!(cache.len(), 1);
    }
}
