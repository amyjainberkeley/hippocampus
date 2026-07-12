# ADR-0035 — V2-P12 chat surface via `AnyLanguageModel` + `foundation-models-utilities` + MLX-Swift (parallel track to ADR-0033)

- Status: **Proposed** (2026-07-13; awaits CEO ratification via `docs/AGENT_QUESTIONS.md`)
- Owners: **Director-Brain** (proposal + Phase 7 PR 18 implementation seat); **CSO** (veto-gate on network-provider trait exclusion — zero-network invariant)
- Reviewers: CTO (adapter-tier discipline, Phase-7 sequencing); CSO (protected-set — see below); CEO (ratification via AGENT_QUESTIONS)
- Phase: **Phase 7 PR 18** (V2-P12 chat surface — SwiftUI recall/chat UI)
- **Protected-set: YES.** Compile-time exclusion of AnyLanguageModel's cloud provider traits (`ClaudeProvider`, `GeminiProvider`, `ChatCompletionsProvider`, etc.) is a CSO veto-gate: the zero-network invariant (`AGENT_PROTOCOL.md` §4) is enforced *by construction* here, not by runtime policy. Any change to the enumerated provider-trait allow-list requires CSO sign-off per `AGENT_PROTOCOL.md` §5.
- **Launch-blocker: NO for v1.0.** The chat surface is Phase 7. If AnyLanguageModel is unfit at V2-P12 kick, fall back to hand-written `LanguageModelSession` on MLX-Swift (see Amendment path). ADR-0033 (`mci-coreml-bridge`) remains the brief-authoring path for v1.0 and is not affected by this ADR.
- **Relationship:** *Parallel* to ADR-0033 — does NOT collapse it. ADR-0033 continues to own the Rust-side batch brief-author (Qwen3-1.7B FP16 via Core ML through `apps/agent`). This ADR scopes the Swift-side interactive chat surface (V2-P12). Complements ADR-0028 (the brief-author model choice is unchanged; the chat surface's model is Qwen3-4B-4bit MLX, a distinct artifact for a distinct use-case). See cycle 8.40 PR #47 (`docs/research/2026-07-12-anylang-eval-spike.md`) for the two-track rationale.

## Context

WWDC 2026 introduced Apple's `LanguageModel` protocol as a first-class Swift API for on-device generative models. `huggingface/AnyLanguageModel` implements this protocol across multiple providers (Apple on-device, MLX-Swift, and — importantly for our threat model — network providers we must exclude). `apple/foundation-models-utilities` ships transcript/history/Skills primitives against the same protocol.

For the V2-P12 chat surface, the natural consumer is Swift (the SwiftUI recall/chat UI in `apps/recall-ui/`). Hand-writing `LanguageModelSession`, streaming iteration, ChatML plumbing, and transcript/history state for PR 18 is exactly the boilerplate these packages compose off-the-shelf. Cycle 8.40 PR #47 evaluated whether we should collapse ADR-0033 into AnyLanguageModel *wholesale*; the verdict was **Partial** — preserve ADR-0033 for the Rust-side batch brief-author, adopt AnyLanguageModel for the Swift-side V2-P12 chat surface only. This ADR is the Track-2 landing per that verdict.

Prior ADRs number through 0034 (per cycle 8.35 PR #8 — the fleet-authored-PR merge policy). This is ADR-0035.

## Decision

1. **Adopt `huggingface/AnyLanguageModel` as the V2-P12 chat-session substrate.** `LanguageModelSession`, streaming response iteration, transcript state, and prompt-template plumbing are consumed as library code rather than hand-written in PR 18.

2. **MLX-Swift as the local provider.** Chat model = `mlx-community/Qwen3-4B-4bit` (via `MLXLanguageModel(modelId:)`). Apple's on-device provider is *allowed* as a fallback path where available, but MLX is the primary and the target of the footprint/latency SLOs.

3. **Compile-time exclusion of cloud providers (zero-network invariant enforcement).** The Swift package's `Package.swift` enumerates *only* `[MLX, Apple]` traits. `ClaudeProvider`, `GeminiProvider`, `ChatCompletionsProvider`, and any other network-remote provider trait are excluded at compile time. A stray import of a remote-provider symbol MUST fail to build. This is the CSO veto-gate surface.

4. **`apple/foundation-models-utilities` for Skills / transcript primitives.** Adopt the Skills API as the injection point for MCI-side context (recall context, brief context, retrieved episodes). Transcript-history modifiers are consumed directly.

5. **Bundle the MLX Qwen3-4B model into the DMG.** ~2.4 GB (mlx-community 4-bit). This is comparable to the current Qwen3-1.7B FP16 (~3.4 GB extracted) that ADR-0028 ships. If the chat model proves out, a future ADR may retire the 1.7B brief-author in favor of a shared 4B artifact — a net-wash-to-net-win on total bundle size — but that consolidation is out of scope here.

6. **ADR-0033 STAYS.** The Rust-side batch brief-author remains on `mci-coreml-bridge` for v1.0. No change to `apps/agent`, `core/brief-eval`, the FP16 install base, or the 4/8 strict eval gate.

7. **CI guard (new).** A build-time lint fails the build if `AnyLanguageModel.RemoteProvider` or any of its known subclasses (`ClaudeProvider`, `GeminiProvider`, `ChatCompletionsProvider`, or any type conforming to the `RemoteLanguageModel`/network-capable trait) is imported or referenced anywhere outside a narrow test-only allowlist (`adapters/macos/**/Tests/RemoteProviderExclusionTests/**`). Implementation: `scripts/verify-no-remote-providers.sh` grepping the Swift sources for the trait/type names, plus a Package.swift trait audit that fails if the enumerated `traits` set is not exactly `[MLX, Apple]`. Wired into the Phase-7 CI job. This is the belt-and-braces net for the compile-time exclusion in item 3.

## Alternatives considered

- **(A) Adopt AnyLanguageModel *this ADR*.** Selected. Rationale: cycle 8.40 PR #47 verdict; Swift-side natural fit; ~1.0–1.5 cycles saved on PR 18.
- **(B) Reject — hand-write `LanguageModelSession` + streaming + transcript primitives on top of MLX-Swift directly.** Rejected: costs ~1.0–1.5 cycles of PR-18 work with no offsetting benefit; foregoes the automatic upgrade path when Apple's `LanguageModel` protocol stabilizes.
- **(C) Defer decision to Phase 7 kick.** Considered. Advantage: more data on AnyLanguageModel's v1.0 stability (currently v0.8.0 line). Disadvantage: leaves PR-18 scoping ambiguous through cycles 8.41–Phase-7-1, and the fallback (item Amendment path below) is cheap enough that landing Proposed now is the higher-value option.
- **(D) Collapse ADR-0033 wholesale into AnyLanguageModel.** Rejected in PR #47. See that memo §"What ADR-0033 still needs to own" — Rust-callable inference, brief-eval CI pathway, footprint-tier switching, RAG-context injection from the Rust brain, and the Qwen3-1.7B FP16 install base all argue for a two-track answer.

## Consequences

### Positive

- **~1.0–1.5 cycles saved on Phase 7 PR 18.** Transcript management + session/streaming primitives are library code, not hand-written.
- **Automatic upgrade path.** When Apple's `LanguageModel` protocol stabilizes (post-WWDC 2026), our chat surface is already conforming to it via AnyLanguageModel; no rewrite.
- **Skills API is a reference architecture for context injection.** `foundation-models-utilities` Skills is directly analogous to what we would build for MCI's recall-context / brief-context injection; adopting it aligns us with an Apple-blessed pattern.
- **Zero-network invariant enforced at build time.** Compile-time trait exclusion + CI guard is stronger than a runtime allow-list.

### Negative

- **New Swift dependency (`AnyLanguageModel` + `foundation-models-utilities`).** ADR-0008's dependency-addition gate applies at Phase 7. CSO reviews the provider-trait surface; CTO reviews the version-pin discipline (pre-1.0 package — pin exact, do not track main).
- **Bundle size ~+2.4 GB.** Qwen3-4B-4bit MLX. Mitigated by the future consolidation option (retire the 1.7B if 4B proves out as brief-author too — later ADR, not this one). Interim: net bundle grows.
- **Compile-time discipline requires vigilance.** A future contributor could accidentally add a cloud-provider trait to `Package.swift`. Mitigation: CI guard (item 7 above) fails the build. Belt and braces.
- **Two on-device runtimes co-resident (Core ML + MLX).** Core ML for embedder / NER / brief author; MLX for chat. Two allocators, two model loaders, two footprint profiles. Instrumented in `docs/PERF_LOG.md`. Chat model unloads on idle per Phase-7 unload policy.
- **AnyLanguageModel is pre-1.0 (v0.8.0 line).** API churn risk. Mitigation: pin exact version; re-eval per minor bump.

## Amendment path

If AnyLanguageModel proves unfit at Phase 7 kick — footprint regresses on 8 GB M1 MBA, MLX provider hangs or leaks, API churns unacceptably between now and V2-P12, or the provider-trait surface changes such that compile-time exclusion becomes fragile — the fallback is to roll back to a hand-written `LanguageModelSession` on top of MLX-Swift directly (Alternative B above). No user-facing impact until Phase 7 PR 18 ships. ADR-0033's Rust-side path is untouched by this fallback. The amendment lands as ADR-0035 v2 with Status: Superseded on this document.

## References

- `docs/research/2026-07-12-anylang-eval-spike.md` — cycle 8.40 PR #47 spike memo (the Partial verdict this ADR implements).
- `docs/decisions/0028-brief-author-model-qwen3-1.7b-coreml.md` — brief-author model (unchanged by this ADR).
- `docs/decisions/0033-mci-coreml-bridge-rename.md` — the parallel-track ADR for v1.0 brief-authoring (unchanged).
- `docs/decisions/0034-fleet-authored-pr-merge-policy.md` — most recent prior ADR (ADR number cadence check).
- `docs/DESIGN.md` §3 — footprint SLO (re-validated at Phase 7 kick).
- `docs/AGENT_PROTOCOL.md` §4 — zero-network invariant (the veto-gate this ADR strengthens via compile-time exclusion).
- `huggingface/AnyLanguageModel` — Swift package implementing Apple's `LanguageModel` protocol across providers.
- `apple/foundation-models-utilities` — Skills + transcript-history primitives (Apache-2.0).
- `mlx-community/Qwen3-4B-4bit` — the MLX chat-model artifact.
