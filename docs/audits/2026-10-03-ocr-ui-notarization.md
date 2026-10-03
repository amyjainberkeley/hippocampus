# OCR preview and private notarization follow-up

The private Hippocampus 0.2.0 candidate from
`4983f6cbeb376125b0df5b9125741047015c52d3` is now Apple-notarized and stapled.
It is **not installed or publicly available**, and no finished DMG was produced.
This follow-up qualifies specific UI and release steps; it does not certify
end-to-end capture or general screenshot accuracy.

## Native OCR preview

Computer use verified the existing isolated production-view fixture with a
fabricated two-sentence screenshot. It uses the production re-read section,
view model and local reader, an authenticated encrypted fixture blob, and the
actual frozen OCR worker. The fixture's saved garbled text remained visible
and unchanged while a separate result showed both expected sentences exactly.

**Copy new reading** pasted those exact two sentences into a new TextEdit
document. The synthetic paste was undone after checking. Two repeated reads
completed with the same result, and the isolated review app was then closed.
This did not use the owner's screenshot or rewrite historical OCR or indexes.
It is an isolated production-view check, not the installed candidate's full UI.

The small fixture finished before computer use could select Cancel, so there
is no live cancellation claim. Original-image zoom also remains unverified in
the UI. Existing source tests are separate evidence for these paths.

## Apple acceptance

Once the desktop was accessible, the existing `notarytool-profile` worked
without replacing credentials. Apple accepted submission
`88e0b6e7-7ded-4a6d-ac34-393b28561b03` for the complete original candidate.
The app was stapled. Staple validation, deep strict signatures, Gatekeeper
execution assessment, `syspolicy_check distribution`, all six executable hashes,
and complete source/payload provenance passed afterward. Gatekeeper reported
**Notarized Developer ID**. Team identity remains `BV6KGKFKP4`.

The first post-staple check runner lacked `/usr/sbin`, so it could not spawn
`spctl`. The corrected allowlisted PATH ran the unchanged checks successfully;
the failed runner is retained in the private evidence. No check was skipped.

Source digest:
`c52f87c4fb06c49a287a4f8cd70d8b842d82cb0f7a48acd292416a16a69e4d99`.
Payload digest:
`125d94e78a4dca51fd8016ffe95c36e42ca506f9012fbb569cc5b60c0a3bfd64`.
The candidate was not rebuilt or relabeled as the later documentation/tooling
HEAD. The [candidate receipt](../release/candidate-0.2.0-4983f6c-2026-10-03.json)
identifies the original accepted app.

## Installer launch check repair

The canonical installer initially failed its mandatory 20-second onboarding
check in a detached checkout under `/private/tmp`. Process observation showed
the correct direct child alive from 0.789 through 19.428 seconds, but Foundation
launched it through `/tmp`. The verifier compared command text literally and
mistook the same executable's path alias for a missing child. Cleanup worked.

The source verifier now compares the direct child's executable file identity.
It accepts an alias of the required executable while rejecting identical bytes
copied into another app bundle. On macOS it uses the executable path from
`ps`; portable Linux fixtures use the kernel's `/proc/<pid>/exe` link. The
deadline, parent-child requirement, disposable home, and cleanup are unchanged.

The new alias regression failed before the fix. After the fix, the complete
contract passed immediate startup, delayed startup under the full 20-second
deadline, a symlink path containing spaces, and rejection/cleanup of a different
bundle's executable. The repaired verifier also passed against the real app at
the originally failing `/private/tmp` path. All 16 release-safety tests and all
230 release-contract checks passed. Independent review found no actionable
issue. No product runtime code changed in this follow-up.

The detached checkout was then moved to a canonical path under `/Users`.
The **unchanged exact-4983f6c installer** passed its original 20-second launch
gate there. This preserves the candidate's exact source provenance instead of
editing it or bypassing a release check.

## Installer and installation remain incomplete

The second installer attempt re-signed its separate working copy and passed
signature verification. The Mac subsequently became locked again, and the
existing notary profile was unavailable at the app submission step. The
installer stopped before producing a DMG. Credentials were not recreated,
replaced, or repeatedly polled. No release gate was disabled.

The original accepted candidate was preserved separately from this re-signed
installer copy. Its staple, strict signature and complete provenance were
rechecked successfully after the installer failure. The failed copy is **not**
the qualified notarized candidate. Private logs and copies remain outside Git.

The installed app remains `f4f7bf1`, version 0.1.0. No owner-store backup,
migration, replacement, permission change, or microphone capture occurred.
The next live steps require the desktop: controlled shutdown, consistent
ciphertext backup, verified whole-bundle installation, ordinary owner permission
grants, and actual capture/recall/shortcut checks. Cancellation, zoom, first-run
onboarding, clean-machine behavior and schema-aware recovery remain open.
The known unbundled Apple Vision fallback failures remain open as well.

A separate public-release prebuild check still fails because
`release-models.json` has its existing `UNPROVISIONED` archive URL and checksum.
The local bundled Arctic model passed verification; that does not provision
the immutable hosted archive required by the release pipeline. This earlier
release prerequisite remains explicit and was not bypassed or filled with a
placeholder URL.

Superapp, websites, and signup email are unchanged by this checkpoint.
