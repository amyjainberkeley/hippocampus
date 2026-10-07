# Diagnostic candidate installation and foreground limitation

The exact `8e82e031eae81e06036e6451140aa723605ba90b` candidate is installed at
`/Applications/Hippocampus.app`. It retains the OCR improvements and adds the
content-free AX traversal diagnostics. This is a private owner installation,
not a public download or a claim that live capture is working end to end.

## Build and installation evidence

All five minimal-environment release commands covering six shipping executables
passed. The release assembler checked source and resource provenance, executable
hashes, nested signatures, App Group and embedded models. The unchanged
20-second disposable-home launch passed with onboarding attached. Apple accepted
app submission `65c5fc37-0472-485b-8896-c5316da2acec`; stapling, signature,
Gatekeeper and distribution-policy checks passed. Installed provenance, nested
signature, staple and Gatekeeper checks passed after the swap.

The running parent and its writer/helper were quit normally through Activity
Monitor, then the remaining Recall child was quit normally. No force quit was
used. The existing exclusive writer lease was acquired without replacing its
inode or changing crash state. A ciphertext backup of 1,482 files / 320,902,977
bytes was hash-verified and the source remained unchanged through the atomic
whole-bundle swap. Eight existing MCP readers were preserved. The new parent,
helper, writer and Recall processes were observed running from the canonical
bundle. Open-file inspection confirms the writer and Recall use the expected
`MCI/mci.sqlite`; the writer holds the existing Hippocampus writer lease.

The retired `4983f6c` bundle is retained at
`/Applications/.hippocampus-ax-upgrade-20261007/Hippocampus.app`. The still older
retired bundle and its mapped readers are also preserved. Neither retired
writer nor Recall may be launched against the upgraded store. There was no
rollback or historical OCR/index rewrite. The existing `4983f6c` private DMG is
unchanged; no new diagnostic DMG was created.

Private candidate, notarization and install evidence resides in
`/Users/amy/Hippocampus-release-candidates/20261007-ax-diagnostics`.
The private ciphertext backup is
`/Users/amy/Hippocampus-private-backups/20261007-before-ax-diagnostics`.

## What the live diagnostics establish

The installed helper emitted content-free unknown-classification diagnostics
for `children-incomplete` (status 0, depth 0, zero descendants) and `depth-limit`
(no invented AX status, depth 3, three descendants). Neither line reported an
ancestor link. These lines have no app identity and share the existing
30-second limiter. They cannot be attributed to TextEdit, used to establish a
cycle, or used as a reason to relax traversal/privacy rules.

A fabricated TextEdit document was entered, focused through the UI controller
and saved privately. This did not establish the system foreground PID. To
measure that missing prerequisite, the existing standalone screen-proof fixture
was built and opened. Its numeric receipts independently compare AppKit state,
system foreground PID and WindowServer window identity. UI Raise and text clicks
made the fixture's own AppKit window active, key and focused, while system
foreground samples continued to identify the installed Recall process.
The complete 120-second session emitted 121 receipts, zero eligible samples,
zero generated phrases and one terminal record. The test never clicked Generate
and did not weaken its foreground requirement. The fixture was closed afterward;
a controller observation briefly reopened it, and that ungenerated second
session was closed without being counted as qualification evidence.

The agent's capture receipt is live and uses the expected database, but still
reports an old last-stored-frame timestamp and `denylist-source`. Built-in
policy excludes Recall, consistent with the observed system foreground state.
This is evidence of a failed automated exposure prerequisite, not proof that
an ordinary foreground TextEdit window is rejected. The earlier TextEdit
attempt and missing search result therefore leave capture unqualified; they
do not diagnose the user-facing capture path. The UI controller's local focus
and the system foreground observation disagree; this run does not establish
which system/controller mechanism causes that disagreement.

No permission grants, denylist changes, microphone capture, private transcripts
or raw screen content were needed for this diagnosis. The next genuine capture
check requires a user-visible application with independently matching system
foreground identity, followed by fresh screen-OCR/image storage and Recall/MCP
readback. Public downloads, cold-machine behavior, onboarding, shortcuts,
cancellation/zoom and recovery remain unqualified.
