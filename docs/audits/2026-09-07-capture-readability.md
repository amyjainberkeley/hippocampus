# Capture And Recall Corrections

This checkpoint addresses existing capture diagnostics and memory readability.
It does not substitute another feature or test count for the owner's live gates.

## OCR Transcript

Overlapping recognition regions can read the same physical line more than
once. The complete ordered readings still go through the original secret
check. Only afterward does transcript compaction remove byte-identical text
at substantially overlapping image positions. Different positions, uncertain
geometry, different literal readings and Unicode byte sequences remain.
The cleaned text passes the secret check again because removing a repeated
line can create new multiline adjacency. The original 64 KiB limit applies
before compaction; timeout and screenshot-retention gates are unchanged.

Comparison work is bounded per literal reading. When the position cache is
full, text is retained rather than guessed to be a duplicate. This is a small
transcript improvement, not semantic correction, document reconstruction or
lossless OCR. Split-word and conflicting readings deliberately remain.

Tests first reproduced duplicate wire output and a newly adjacent secret.
A separate red test caught Swift's canonical Unicode equality erasing a
different byte sequence; keys now use literal UTF-8 bytes. Real Vision on two
synthetic labels produced five lines/55 bytes, then four lines/40 bytes after
compaction. The fixture requires an actual duplicate before asserting removal.
It is not a measurement over the owner's memory or a general compression rate.

## Latest Context

Daily Review now hydrates only its latest event through bounded full-text
reads, checks the event identity before and after that read, strips the known
leading internal header, then limits the preview to 400 characters. It does
not fetch every event's full text. Failed, deleted, replaced or superseded
reads fall back without discarding the otherwise available day. Date changes
invalidate pending work and immediately clear the previous day's context.
The original stored text remains accessible through the evidence inspector.

## Stream Diagnostics

The terminal capture breadcrumb now names the operation: stream delegate,
startup teardown, focus rebind teardown, permission pause or permission resume.
It emits fixed domain tokens and numeric error codes, never descriptions,
underlying errors, userInfo, window titles, URLs or screen content. Retired
stream filtering, one-shot failure claims and exit statuses 81/82 remain.
The packaged supervisor directs these breadcrumbs to its existing local
helper diagnostic file. Identifying a failure site is not fixing its cause.

Tests exercise hostile error data, concurrent callbacks, replacement identity,
failed teardown and actual subprocess stderr/exit behavior. Test subprocesses
use explicitly constructed environments. Repository instructions now require
minimal build/test environments and prohibit credential-bearing diagnostics.

## Verification And Limits

- Optimized local capture: 758 tests pass.
- Optimized local Recall: 510 XCTest and three Swift Testing cases pass.
- Release contract: 224 assertions pass; sixteen release-safety tests pass.
- A live-probe test assumed that an unknown application must always reach the
  final failsafe rule. A real secure-field result correctly fired earlier.
  Its replacement requires suppression by one of those valid rules, with no
  skip and no change to production privacy behavior.
- Existing framework diagnostics and test compiler warnings remain; this is
  not a zero-warning claim or a security certification.
- Hosted `0bb07eb` capture still fails OCR completeness. The runner is an
  arm64 virtual Mac without an advertised Neural Engine; baseline accurate
  recognition can already exceed the production deadline. The earlier full
  release-contract run is now confirmed passing. Neither result is inferred
  from the other.
- Fresh screen/image/restart/client proof, complete privacy recovery,
  overnight reliability and second-Mac qualification remain open.

Use [STATUS](../STATUS.md) for installed source and distribution state. This
checkpoint changes neither website deployment nor its audience. No user data,
private diagnostic log, credential, permission reset or public DMG is included
in source publication.
