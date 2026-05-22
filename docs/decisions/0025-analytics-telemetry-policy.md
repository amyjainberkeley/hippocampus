# ADR-0025 — Analytics + Telemetry Policy

- Status: Accepted (2026-05-21; ratifies the analytics policy decision from the CEO EOD discussion).
- Owners: **Director-Recording** (crash reporter integration, already landed PRs #109/#116) + **Director-Sync-Core** (analytics endpoint)
- Reviewers: CSO (reviews payload schema to verify content-free invariant); CTO (sequencing); CEO (ratification)
- Phase: 7 (onboarding opt-in toggle) + post-launch (enterprise self-host)
- **Protected-set: no.** Analytics payload is content-free (no event text, no URLs, no window titles). However, CSO reviews the payload schema to verify the content-free invariant holds. Normal review process with CSO payload-schema check.

## Context

MCI captures the most sensitive data stream possible. Users who choose a privacy-first product expect minimal telemetry. But crash reports and anonymous usage statistics improve the product — finding bugs, understanding which features are used, and identifying performance regressions.

The crash reporter (PRs #109/#116) already ships with a dual-gate pattern: `MCI_CRASH_REPORT_URL` (endpoint) + `MCI_CRASH_REPORT_OPTED_IN=1` (user consent). Path-scrubbing removes filesystem paths. 200-character truncation limits stack trace content. This ADR extends the same pattern to usage analytics.

## Decision

### 1. Opt-in by default

Analytics collection is OFF by default for the personal tier. The user opts in during onboarding (step 5, already scaffolded in PR #125) or later in Settings → Privacy → Analytics.

The toggle is a single boolean: "Help improve Hippocampus by sharing anonymous usage data." Default: OFF.

### 2. What's collected (when opted in)

The analytics payload is a JSON object sent via HTTPS POST:

```json
{
  "install_id": "uuid-v4",
  "app_version": "1.0.0",
  "os_version": "macOS 15.3",
  "uptime_seconds": 28800,
  "event_count": 4523,
  "episode_count": 42,
  "brain_size_mb": 3200,
  "features": {
    "recall_used": true,
    "mcp_used": true,
    "brief_used": false,
    "workspace_used": false,
    "browser_ext_used": true
  },
  "capture": {
    "keyframes_today": 342,
    "ocr_events_today": 289,
    "suppressed_today": 156,
    "avg_fps_today": 2.1
  },
  "ts": "2026-05-21T18:00:00Z"
}
```

#### 2.1 What is NOT collected

- **No event text.** No OCR content, no window titles, no URLs, no page content.
- **No identifiers beyond `install_id`.** The `install_id` is a random UUID generated at install time. It is NOT tied to Apple ID, email, device serial, or any other identifier. It exists solely to deduplicate analytics submissions.
- **No IP geolocation.** The analytics endpoint does not log client IPs (see §4).
- **No user-agent.** Dropped at the endpoint.
- **No behavioral sequences.** No "user opened recall at 2pm then searched for X." Only aggregate counts.

### 3. Content-free invariant (enforced)

The analytics payload struct is tested:

```rust
#[test]
fn analytics_payload_contains_no_user_content() {
    // Assert that AnalyticsPayload has no String fields beyond
    // install_id, app_version, os_version, ts.
    // Any new String field requires CSO review.
}
```

This test is a compile-time guardrail. Adding a new string field to the analytics payload struct fails the test, forcing a CSO review of the new field before it can ship.

The CSO reviews the payload schema at each change. Any field that could leak user content is a veto.

### 4. Hippocampus analytics endpoint

- Standard HTTPS POST to `https://analytics.hippocampus.ai/v1/ingest`.
- JSON payload (§2).
- No third-party analytics SDK. No Mixpanel, no Amplitude, no Google Analytics, no Segment. We control the entire pipe.
- Server-side: the endpoint stores payloads in a Postgres table. No client IP logging — the server drops `X-Forwarded-For` / `CF-Connecting-IP` before storage. Server access is restricted to the engineering team.
- Submission frequency: once per day, at a random time within the user's active session (jittered to avoid thundering herd at midnight UTC).
- Payload is sent in cleartext JSON over TLS. No additional encryption layer (the payload is content-free; TLS is sufficient).

### 5. Enterprise self-host

Enterprise customers can redirect all analytics to their own endpoint:

```bash
export MCI_ANALYTICS_URL="https://analytics.corp.example.com/v1/ingest"
```

When `MCI_ANALYTICS_URL` is set:
- All analytics payloads go to that URL instead of Hippocampus's endpoint.
- The payload format is identical (§2).
- Hippocampus receives nothing.
- IT controls the data, the retention, and the access.

This is the same pattern as the crash reporter (`MCI_CRASH_REPORT_URL`). Both can be set via workspace policy (ADR-0019 workspace settings) or environment variable.

### 6. Crash reporter integration

The crash reporter (PRs #109/#116) is a separate opt-in from usage analytics:

- `MCI_CRASH_REPORT_OPTED_IN=1` — crash reports (stack traces, path-scrubbed, 200-char truncated).
- Analytics opt-in (this ADR) — usage statistics (counts, booleans, no content).

Both can be independently enabled/disabled. The onboarding step 5 toggle controls both with a single "Help improve Hippocampus" switch, but Settings → Privacy shows separate toggles for granular control.

### 7. Opt-out is immediate and complete

When the user disables analytics:
- No further payloads are sent.
- The local `install_id` is regenerated (so if the user re-enables later, there is no correlation with prior data).
- No "we'll stop after the current batch" delay. Toggle off = immediate stop.

## Consequences

- **Positive:** Opt-in default respects the trust thesis. Users who choose a privacy product get privacy by default.
- **Positive:** Content-free payload with a compile-time test prevents accidental content leakage.
- **Positive:** No third-party SDK means no supply-chain risk from analytics dependencies and no data leaving our pipe.
- **Positive:** Enterprise self-host means IT gets full control — a selling point for security-conscious buyers.
- **Negative / tradeoff:** Opt-in means low adoption rates for analytics (industry average: 10-30% opt-in). Product decisions will have less data than competitors who collect by default. Acceptable — trust is the product.
- **Negative / tradeoff:** Building our own analytics endpoint instead of using a third-party service is more engineering work. Mitigated by the simplicity of the payload (one JSON POST per day).
- **Negative / tradeoff:** `install_id` regeneration on opt-out means we lose longitudinal data for users who toggle. Acceptable — privacy over analytics continuity.

## Alternatives considered

1. **Opt-out by default (collect unless disabled).** Rejected: contradicts the privacy-first product thesis. A screen recorder that collects telemetry by default would be a trust devaluation per CRS competitor analysis.
2. **Differential privacy (add noise to counts).** Rejected for v1: the payload is already aggregate counts with no content. Differential privacy is appropriate when individual records are sensitive — our records are not (count of events is not sensitive).
3. **Third-party analytics SDK (PostHog self-hosted).** Rejected: adds a dependency, widens the supply chain, and PostHog's default instrumentation captures more than we want. Rolling our own is safer for this product.
4. **No analytics at all.** Rejected: flying blind on usage patterns makes it harder to prioritize features and find bugs. Opt-in with a content-free payload is the minimum viable telemetry.

## CSO sign-off (placeholder — owed at first payload-schema PR)

Analytics payload is content-free by design and by test. No event text, no URLs, no window titles. `install_id` is a random UUID, not correlated with identity. CSO reviews the payload struct at each change. Each PR carries the sign-off block.

— CSO, pending

## References

- **PRs #109, #116** — crash reporter (dual-gate pattern, path-scrubbing — this ADR extends the same pattern).
- **PR #125** — onboarding 5-step scaffold (step 5 = analytics opt-in toggle).
- **ADR-0001** — privacy posture (local-first; analytics is the one exception, and it's opt-in + content-free).
- **ADR-0019** — workspace server (enterprise self-host endpoint can be set via workspace policy).
