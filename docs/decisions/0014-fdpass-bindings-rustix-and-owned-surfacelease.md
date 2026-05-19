# ADR-0014 — fd-pass bindings (rustix) + owned `SurfaceLease` IPC seam

- Status: Accepted (2026-05-19; human CEO ruled the binding choice live in the Track-A enabler session — see `docs/AGENT_QUESTIONS.md` § "2026-05-19 — CSO/CEO — socketpair(2)/SCM_RIGHTS bindings + owned SurfaceLease"). Protected-set authoring (AGENT_PROTOCOL §5).
- Owners: **CSO** (binding contract; protected-set veto) + **Director-Sync-Core** (the Rust core seam / IPC transport implementation)
- Reviewers: CEO (ruled the bindings fork); CRS Security-Signal (ADR-0008 supply-chain audit of the new dep); CTO (the `core::capture` seam shape, ADR-0006)
- Phase: 1 (live-capture enabler sequence — "PR-4")
- **Protected-set: yes** (AGENT_PROTOCOL §5 — `core/**` IPC + the bytes/fds that cross the helper→core boundary; a new dependency on the IPC seam)
- Relationship: implements the surface-handle-over-IPC timing contract owed by ADR-0006 (async+push seam) and ADR-0007 (separate signed helper, `AF_UNIX` + `SCM_RIGHTS`, per-frame ack). Feeds — never bypasses — the ADR-0013 cascade (the cascade still runs in the helper, before any fd is sent).

## Context

The macOS capture helper is a separate signed process (ADR-0007). A surviving (`.allow`) frame's GPU surface must reach the Rust core **without copying pixels across the boundary**: the helper passes the surface's file descriptor out-of-band via `SCM_RIGHTS` over an `AF_UNIX` `socketpair(2)`, referenced by the `fd_index` ordinal already defined in `core::ipc::Message::StateTransitionEvent`.

Two things blocked this and are decided here:

1. **The fd-pass binding.** `core/` (and `apps/agent/`) are `#![forbid(unsafe_code)]` (AGENT_PROTOCOL §4 cross-platform-seam invariant + the project's hardening posture). `forbid` is the strictest lint level — it **cannot** be locally re-enabled by an inner `#[allow(unsafe_code)]`. Hand-written `sendmsg`/`recvmsg` + `SCM_RIGHTS` ancillary parsing is the single highest-risk class of `unsafe` for a privacy daemon. The binding library is therefore a material, protected-set fork.

2. **The surface carrier type.** `core::capture::StateTransitionSender` was a placeholder `mpsc::Sender<StateTransition<'static>>` — a borrowed `'frame` surface cannot cross either the async-push channel (ADR-0006) or the helper-process boundary (ADR-0007). The skeleton's own docs anticipated "an owned-but-still-opaque `SurfaceLease` type that carries the OS pool retain across the channel while the per-frame ack discipline of ADR-0007 enforces the deadline." That type is now required to land the fd-pass seam.

## Decision

### 1. Binding = `rustix` (safe wrapper; `forbid(unsafe_code)` preserved)

`rustix` is adopted as the `socketpair(2)` / `sendmsg` / `recvmsg`+`SCM_RIGHTS` binding. It exposes a **safe** API (`socketpair`, `sendmsg`, `recvmsg`, `SendAncillaryBuffer`/`RecvAncillaryBuffer`, `RecvAncillaryMessage::ScmRights` yielding `OwnedFd`s), so **no `unsafe` appears at our call sites and `#![forbid(unsafe_code)]` stays intact** in `core/`. The `unsafe` lives inside the audited `rustix` crate, not in MCI's privacy-critical code.

Alternatives considered:
- **`nix`** — also a safe `socketpair` + `ControlMessage::ScmRights` API; rejected on dependency-surface grounds (broader transitive graph than rustix's lean, syscall-focused crate) and weaker fit for a minimal audited IPC seam. Not wrong; rustix is the tighter choice.
- **Direct `libc` shim** — smallest dependency, most control, but introduces hand-written `unsafe` `SCM_RIGHTS` parsing into the privacy daemon and would force removing/relaxing the crate-level `#![forbid(unsafe_code)]` posture (an inner `allow` cannot override `forbid`). **CSO-disfavored and rejected**: the posture is load-bearing; trading it for a marginally smaller dep on the most dangerous code path is the wrong trade for MCI.

`rustix` is added with `default-features = false, features = ["net", "std"]` — `use-libc-auxv` (Linux-init only) is dropped; macOS uses rustix's libc backend regardless; the seam stays OS-agnostic (no `#[cfg(target_os)]` in `core/`). `SOCK_CLOEXEC` is not a `socketpair(2)` flag on Apple platforms, so close-on-exec is set portably via one `fcntl` call on both ends — still no `#[cfg(target_os)]`.

### 2. `rustix` is a PROTECTED-SET dependency — ADR-0008 supply-chain gate

Adding `rustix` to the IPC seam is a protected-set dependency addition (AGENT_PROTOCOL §5 — "dependency additions to any crypto/capture/sync crate or the agent shell"). Per the ADR-0008 supply-chain discipline that the P1 crypto dependencies satisfied, a CRS Security-Signal supply-chain / CVE review of `rustix` (and any new transitive deps) is **owed and recorded in `docs/RESEARCH_DIGEST.md` before PR-4 merges**. No clean audit ⇒ no merge. (This ADR records the requirement; the audit artifact lives in RESEARCH_DIGEST.)

### 3. Owned `SurfaceLease` — RAII pool-return, OS-agnostic

`core::capture` gains `SurfaceLease`: an opaque, **owned**, `Send` carrier with an adapter-supplied `Box<dyn FnOnce() + Send>` releaser that returns the underlying OS surface to its pool. `core/` never inspects the releaser (ADR-0003 — the OS payload stays in the adapter). `StateTransition` drops its `'frame` lifetime and carries a `SurfaceLease`; `StateTransitionSender = mpsc::Sender<StateTransition>`.

The release-timing contract of ADR-0006 §5.1 / ADR-0007 is now enforced by **RAII**: the releaser runs **exactly once** — on explicit `release()` or otherwise on `Drop` — on **every** exit path (deliver / suppress / backpressure-drop / error / panic-unwind). This is the ADR-0013 Amendment 1 §3(d) "no `IOSurface` pool-stall on any path" invariant expressed in the type system. `SurfaceHandle<'frame>` is retained unchanged for the in-callback borrowed path (ADR-0006).

### 4. `SCM_RIGHTS` receive-path hardening — binding CSO veto-gate

The CEO attached this as a binding condition. `core::ipc::fdpass::recv_with_fds` MUST, on every call, and a CSO structural review MUST assert from the diff:

- **(a) Bounded received-fd count.** The ancillary buffer is sized for exactly `MAX_SCM_FDS` (a fixed compile-time ceiling; MCI attaches ≤1 surface fd/event), so a peer cannot make the core allocate an unbounded control buffer. The caller's `max_fds` further caps acceptance; any overflow is rejected.
- **(b) Truncated ancillary rejected.** If the kernel set `MSG_CTRUNC` the message is rejected (`AncillaryTruncated`) — the core never acts on a partially-received fd array.
- **(c) Duplicate / multi-`ScmRights` rejected.** More than one `SCM_RIGHTS` control message, or more fds than budgeted, is treated as hostile and rejected.
- **(d) Close-on-every-error-path.** Every received descriptor is collected into `OwnedFd` immediately; on **any** rejection the collection is dropped before `Err` is returned, so RAII closes every fd. No error path leaks a descriptor.

These properties are unit-tested headlessly against a real `socketpair` (no screen needed): payload+fd round-trip with kernel-object identity proof; over-ceiling request/send rejected; unexpected-fd-when-none-budgeted rejected; over-budget rejected. Widening any of (a)–(d) to "accept on uncertainty" is a CSO-protected change requiring a fresh amending ADR.

### 5. Scope honesty (Track A vs Track B)

This ADR + PR-4 land the **decision, the owned-lease type, and the headlessly-verifiable fd-pass primitive**. They do **not** spawn the helper child, start a live `SCStream`, or claim any footprint/§7-corpus result — that wiring is human-in-the-loop on a real Mac (Track B) and remains gated exactly as ADR-0013 Amendment 1 specifies. `--capture` stays default-OFF.

## Consequences

- Positive: the most dangerous code path in the project (cross-process fd-passing) carries **zero hand-written `unsafe`**; `#![forbid(unsafe_code)]` holds; the receive path is hardened by contract + tests.
- Positive: the `SurfaceLease` RAII guarantee makes "no pool-stall on any path" a *type-system* property, not a review-time hope — strengthening ADR-0013 Amendment 1 §3(d).
- Positive: the seam stays OS-agnostic (ADR-0003) — no `#[cfg(target_os)]` entered `core/`.
- Negative / tradeoff: a new protected-set dependency (`rustix`) on the IPC seam. Mitigated by the ADR-0008 supply-chain gate (RESEARCH_DIGEST audit) and rustix's lean, widely-audited, syscall-focused surface.
- Forces (binding on every future PR): any change weakening receive-hardening (a)–(d), reintroducing a borrowed surface across the channel, or adding `unsafe` to the fd-pass path requires a fresh CSO amending ADR. Every new transitive dep pulled by rustix re-triggers the ADR-0008 check.

## CSO sign-off

Protected-set authoring (AGENT_PROTOCOL §5). The binding choice (rustix), the `forbid(unsafe_code)`-preservation rationale, the receive-hardening invariants (§4 (a)–(d)), and the ADR-0008 supply-chain gate (§2) are binding. The CSO veto is final unless the human CEO overrides; the CEO has ruled the binding choice (rustix) and attached §2 + §4 as binding conditions.

— CSO, 2026-05-19

## Director-Sync-Core sign-off

The `core::capture` owned-`SurfaceLease` refactor and the `core::ipc::fdpass` rustix primitive are Director-Sync-Core's seam scope. Acknowledged: `core/` stays `#![forbid(unsafe_code)]` and OS-agnostic; the §4 hardening is implemented + headlessly tested; helper-child spawn / live `SCStream` is out of scope here (Track B, real machine, CSO-gated per ADR-0013 Amendment 1).

— Director-Sync-Core, 2026-05-19

## References

- ADR-0003 (no OS code above the `CaptureSource` seam), ADR-0006 (async+push seam, surface release-timing), ADR-0007 (separate signed helper, `AF_UNIX`+`SCM_RIGHTS`, per-frame ack), ADR-0008 (supply-chain / CVE gate on protected deps), ADR-0013 + Amendment 1 (cascade-before-encode; §3(d) no pool-stall on any path).
- `docs/AGENT_QUESTIONS.md` § "2026-05-19 — CSO/CEO — socketpair(2)/SCM_RIGHTS bindings + owned SurfaceLease".
- `docs/RESEARCH_DIGEST.md` § "2026-05-19 — CRS Security-Signal — rustix supply-chain audit (ADR-0014 / ADR-0008 gate)".
- `core/src/ipc/fdpass.rs`, `core/src/capture.rs` (`SurfaceLease`).
