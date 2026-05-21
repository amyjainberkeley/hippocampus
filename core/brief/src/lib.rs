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
//! 4. **LLM integration STUBBED.** Real `LlamaBriefAuthor` is deferred.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod model;
pub mod author;
pub mod lifecycle;
pub mod store;
pub mod tripwire;
