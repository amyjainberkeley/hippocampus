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
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

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
