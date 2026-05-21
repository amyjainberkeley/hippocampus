//! `BriefStore` trait + `InMemoryBriefStore` stub.
//!
//! Production `EncryptedBriefStore` lands at P4.x.3 (ADR-0018 §6).

use std::collections::HashMap;
use std::sync::Mutex;

use thiserror::Error;

use crate::model::{Brief, BriefId};

/// Errors from [`BriefStore`] operations.
#[derive(Debug, Error)]
pub enum BriefStoreError {
    /// Caller violated a precondition.
    #[error("brief store: invalid input: {0}")]
    InvalidInput(String),
    /// Storage backend failed.
    #[error("brief store: backend: {0}")]
    Backend(String),
    /// Brief not found for update.
    #[error("brief store: not found: {0}")]
    NotFound(BriefId),
}

/// Persistence surface for briefs.
///
/// Production impl (`EncryptedBriefStore`) encrypts per-brief files
/// under `~/Library/Application Support/MCI/briefs/`. This trait is
/// the OS-free abstraction.
pub trait BriefStore: Send + Sync {
    /// Insert a new brief, returning its assigned id.
    fn put_brief(&self, brief: &Brief) -> Result<BriefId, BriefStoreError>;
    /// Fetch a brief by id. `Ok(None)` for unknown ids.
    fn get_brief(&self, id: BriefId) -> Result<Option<Brief>, BriefStoreError>;
    /// Update an existing brief (state changes, edits, approval).
    fn update_brief(&self, brief: &Brief) -> Result<(), BriefStoreError>;
    /// List all briefs. Production filters by state; stub returns all.
    fn list_briefs(&self) -> Result<Vec<Brief>, BriefStoreError>;
}

/// In-memory brief store for tests. Thread-safe via `Mutex`.
#[derive(Debug, Default)]
pub struct InMemoryBriefStore {
    inner: Mutex<Inner>,
}

#[derive(Debug, Default)]
struct Inner {
    next_id: u64,
    briefs: HashMap<BriefId, Brief>,
}

impl InMemoryBriefStore {
    /// Construct an empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

impl BriefStore for InMemoryBriefStore {
    fn put_brief(&self, brief: &Brief) -> Result<BriefId, BriefStoreError> {
        let mut inner = self.inner.lock().expect("poisoned");
        let id = BriefId(inner.next_id.wrapping_add(1));
        inner.next_id = id.0;
        let mut stored = brief.clone();
        stored.id = id;
        inner.briefs.insert(id, stored);
        Ok(id)
    }

    fn get_brief(&self, id: BriefId) -> Result<Option<Brief>, BriefStoreError> {
        let inner = self.inner.lock().expect("poisoned");
        Ok(inner.briefs.get(&id).cloned())
    }

    fn update_brief(&self, brief: &Brief) -> Result<(), BriefStoreError> {
        let mut inner = self.inner.lock().expect("poisoned");
        if !inner.briefs.contains_key(&brief.id) {
            return Err(BriefStoreError::NotFound(brief.id));
        }
        inner.briefs.insert(brief.id, brief.clone());
        Ok(())
    }

    fn list_briefs(&self) -> Result<Vec<Brief>, BriefStoreError> {
        let inner = self.inner.lock().expect("poisoned");
        Ok(inner.briefs.values().cloned().collect())
    }
}
