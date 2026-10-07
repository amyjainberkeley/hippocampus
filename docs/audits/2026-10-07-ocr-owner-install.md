# OCR update installed; live capture still unqualified

Later October 7 follow-up: the
[diagnostic installation and foreground audit](2026-10-07-diagnostic-owner-install.md)
supersedes this checkpoint's current-install and next-step descriptions. The
installed candidate is now `8e82e03`. The TextEdit attempt below did not verify
system foreground identity, and its AX health lines have no app attribution;
it must not be read as proof of a TextEdit capture defect.

Hippocampus 0.2.0/build 2 from exact source `4983f6c` is now installed at
`/Applications/Hippocampus.app`. Its app and private DMG are Developer ID-signed,
Apple-accepted and stapled. This installs the sharper saved screenshots,
privacy-preserving OCR filtering, explicit local re-read preview and distinct
Recall shortcut. It does not establish working end-to-end capture or repair
historical OCR automatically. Public downloads remain disabled.

## Recovered installer

The October 3 temporary candidate and logs were absent when work resumed on
October 7. The canonical exact-source checkout and its separate re-signed
working app survived. That copy was not treated as the previously accepted app.
The unchanged installer reused its verified payload, passed full provenance and
model checks, and passed the original 20-second disposable-home launch with
onboarding attached. It then signed, submitted and stapled the app and DMG.
No launch deadline, release gate, source head or manifest was bypassed or relabeled.

New Apple submissions are recorded in the
[October 7 receipt](../release/candidate-0.2.0-4983f6c-2026-10-07.json).
The DMG SHA-256 is
`14443edcdcb43c00455a86d9b454b2c19aeb990b250d99ecb435e7dc643fc823`.
Nested signatures, App Group, source/payload hashes, Gatekeeper, distribution
policy and staples pass. The current branch remains newer than the installed
payload; a future build needs its own provenance.

The first dependency setup selected Python 3.9 and rejected the pinned installer
package version. A separate Python 3.11 environment installed the exact hashed
requirements successfully. Neither security settings nor package pins changed.
Artifacts, logs, the accepted app and synthetic fixture now live in a private
persistent folder outside Git and temporary storage.

## Controlled owner upgrade

The old parent, Recall and capture writer were already stopped. Remaining agents
were identified as MCP readers rather than killed by name. Maintenance acquired
the existing exclusive writer lease without replacing its inode or changing the
crash marker. While that lease was held, the encrypted database, WAL, SHM and
complete blob tree were copied to a private nonsynced recovery directory. Every
copied file hash matched, and the source inventory remained unchanged through
backup and replacement.

Old and staged bundles passed full source/payload and signature checks. The
existing fail-closed atomic helper exchanged the complete bundles on the same
filesystem. Canonical installed provenance, nested signatures, staple and
Gatekeeper were checked again. An existing MCP reader was observed mapped to
the preserved retired bundle. No old writer or Recall was relaunched, no
historical records were rewritten, and no automatic rollback occurred. Recovery
still requires an owner decision about post-backup deletions and new data.

Computer use opened the exact installed path. The parent, Recall, helper and
agent processes were observed. System Settings visibly showed Hippocampus's
Screen Recording and Accessibility switches already **on**. Neither switch nor
any other permission was changed. The old unlock/Screen Recording prerequisites
are therefore superseded by this checkpoint; Whisper remains separate.

## Remaining capture blocker

A new TextEdit document displayed four fabricated sentences. The source text
was never injected into the memory database or imported through a CLI. The
check did not produce a stored-frame increase or a matching MCP hit. The MCP
response was degraded and its unrelated historical results were not used.
The synthetic document was closed and saved with the private test evidence.

Content-free capture health reported `failsafe-unknown`, descendant privacy
backstop errors and some focus-race drops. These observations do not yet prove
which AX traversal branch or foreground transition prevented a qualifying check.
Source review confirms that absent focused subroles (`noValue` or
`attributeUnsupported`) are already handled; a descendant error is the
remaining unknown signal in the reported probe line. That error currently
combines failed/malformed reads and traversal-budget exhaustion. The cycle test
reproduces one possible mechanism, not the observed live cause.

The next bounded diagnostic should retain the first failure category, numeric
AX status, traversal depth, node count and self/ancestor-link boolean from
existing reads. It must retain the limiter and all current suppression decisions.
No app-specific exemption or unknown-to-allowed conversion is justified.

The installed update is available for owner testing, but live OCR/storage/recall,
physical shortcuts, full native onboarding, zoom/cancellation, clean-machine
performance and recovery still require qualification. No microphone was used.
Superapp, websites and signup email remain separate.
