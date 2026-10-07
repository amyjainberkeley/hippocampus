# Content-free diagnosis of unknown AX traversal

The installed OCR update's live TextEdit check did not reach stored memory.
Its health line identified an errored descendant privacy probe, but combined
API failures, malformed replies and traversal limits into one outcome. The
specific live cause remains unknown.

The descendant probe now preserves its first failure category, numeric AX
status, depth, visited-descendant count and whether a link to a current ancestor
had already been observed. These fields reach the existing health reporter.
The root is excluded from the descendant count, and budget exhaustion has no
invented AX status. Malformed successful replies retain status zero. Unexpected
thrown errors have no fabricated status or serialized error description.

Array reads retain their existing partial/error cases and bounded children,
with the reason attached. The identifier backstop ignores this additional
metadata. No attribute read, traversal ordering, node/depth limit, positive
precedence or classification changes. Ancestor comparisons use references
already returned by AX; they do not deduplicate or skip cycles. Once recorded,
the first failure is not replaced by later observations.

Only closed enums, numbers and a boolean enter the health snapshot. No attribute
text, element identity, role, label, document name or screenshot is added to the
log. Known classifications remain silent; all unknown diagnostics share the
existing 30-second limiter. No permission or privacy-policy change is included.

## Verification

Eight new synthetic injected-reader regressions first failed with nine missing
diagnostic assertions, then passed. They cover raw API status, malformed and
partial arrays, first-failure preservation, descendant subrole errors, depth
versus shared-node exhaustion, cycles without additional reads, positive
precedence, known leaves and rate-limited health output. All 131 selected AX
tests passed. Full helper suite: **839 tests passed with zero failures** in
40.503 seconds, using a minimal environment and original test budgets.

The previously recorded eight Apple Vision fallback assertions did not fail in
this run. This diagnostics-only change does not claim to fix those earlier
failures or establish cold-machine OCR reliability. Independent read-only review
found no actionable issue in privacy, classification/read-order preservation,
production sink wiring or the limiter. The diff check passes.

Private logs are retained outside Git at
`/Users/amy/Hippocampus-verification/ax-traversal-20261007`.

This is a source checkpoint. The installed signed/notarized app remains exact
`4983f6c` without these new diagnostic fields. A newly built and qualified
candidate is required to observe the actual live failure. No owner store,
settings, permission, public download, Superapp or website changed. Unknown
still suppresses capture; no TextEdit exception or error-to-allowed fallback
has been introduced.
