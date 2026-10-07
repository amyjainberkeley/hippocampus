# Screenshot re-read recovery after unavailable key access

The image provider cached both successful keys and failed key resolution for
the entire app session. That protected passive thumbnail loads from repeated
Keychain requests, but also prevented an explicit **Re-read screenshot** from
recovering after a transient failure. Restarting the app was the only retry.
This availability bug does not establish the cause of the owner's garbled OCR.

The explicit re-read service now uses a separate provider method that allows
one shared retry after a cached failure. Passive image methods retain their
failure cache; a successful key remains cached for the session. Invalid paths
and already-cancelled calls cannot rearm resolution. Each in-flight attempt has
an identity, so a late waiter from an earlier attempt cannot clear or overwrite
the new attempt's result. The protocol default preserves existing providers.

Encrypted-image authentication, file and path checks, image bounds, recognizer
deadlines, privacy review and preview-only behavior are unchanged. No automatic
retry, new permission, plaintext file or historical OCR rewrite is introduced.

## Verification

The initial integration regression failed on the unchanged implementation with
four assertions: explicit re-read stayed unavailable, the image remained
unavailable and both retry-count checks stayed at one. The fix passes that
regression and four additional tests covering repeated failures, rejected and
cancelled requests, 16 concurrent retries with successful-key reuse, and
tampered ciphertext rejection after recovery.

The tests use a real encrypted synthetic PNG, the real image provider and the
real local re-read pipeline. Only key access and the external recognizer are
substituted. The recognizer returns fixed fabricated text; these tests establish
recovery and transport behavior, not OCR model accuracy or real Keychain access.

- Focused image quality/re-read/recovery suite: 11 tests, zero failures.
- Full optimized Recall suite: 546 XCTest cases, zero failures, in 2.131 seconds;
  four Swift Testing cases also pass in 0.107 seconds.
- Both runs used the repository Swift wrapper and a minimal environment.
- Independent read-only review found no blocking issue. It confirmed the
  explicit-only retry and identity ownership, while noting the limits below.

Private test logs remain outside the repository at
`/Users/amy/Hippocampus-verification/screenshot-key-recovery-20261007`.

## Qualification boundary

The installed signed app remains exact `8e82e03`; this source checkpoint has not
been packaged or installed. A currently visible unavailable-image placeholder
reloads only when its image view is reopened, even if a re-read has recovered
the key. Tests exercise cancellation before entry, not cancellation during a
real Keychain lookup or the exact stale-waiter scheduling interleaving.

The owner foreground verification remains pending. No owner memory, screenshot,
Keychain item, permission or installed bundle was changed for this checkpoint.
Public downloads and feeds remain off. Superapp, websites and email are unchanged.
