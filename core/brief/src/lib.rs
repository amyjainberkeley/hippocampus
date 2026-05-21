//! MCI brief authoring pipeline — ADR-0018 scaffold.
//!
//! 5-state lifecycle (Draft → Reviewing → Approved → Synced → Archived),
//! hallucination tripwire (citation validator), pluggable `BriefAuthor`
//! trait, and `BriefStore` persistence surface.
//!
//! This crate is the **scaffold** — types, traits, state machine, tests.
//! The real LLM-backed `LlamaBriefAuthor` lands in a follow-on PR with
//! a separate ADR-0008 dep-gate review. The `StubBriefAuthor` here
//! produces trivial briefs from `EventRecord` slices for testing.
//!
//! # ADR-0018 §4 invariants (LOAD-BEARING)
//!
//! 1. **NO AUTO-APPROVE.** `lifecycle::advance` requires an explicit
//!    `human_approver_id` on the `Approve` action variant. Tests pin this.
//! 2. **Hallucination tripwire is structural.** The tripwire result is
//!    carried on the `Approve` action; `advance` rejects non-empty
//!    violations. Bypassing requires a code change visible in review.
//! 3. **5-state lifecycle is exhaustive.** Every `(state, action)` pair
//!    is handled explicitly with `Ok` or `Err`.
//! 4. **LLM backend trait + stub.** [`llama_backend::LlamaBackend`] is
//!    the pluggable generation surface; [`llama_backend::StubLlamaBackend`]
//!    provides shaped output for tests. Production Core ML backend lives
//!    in `adapters/macos/mci-llama-coreml/`.
//! 5. **`LlamaBriefAuthor`** implements [`author::BriefAuthor`] via a
//!    [`llama_backend::LlamaBackend`], with prompt rendering + citation
//!    parsing. Hallucinated citations (IDs not in input) are filtered.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod author;
pub mod lifecycle;
pub mod llama_author;
pub mod llama_backend;
pub mod model;
pub mod store;
pub mod tripwire;
