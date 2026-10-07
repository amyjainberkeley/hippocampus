# Separate Recall and dictation shortcuts

Hippocampus Recall and the separate Superapp Whisper product both defaulted
to Command–Shift–Space. Which application registered first could determine
which action received the combination.

Hippocampus now defaults to **Control–Shift–Space**. The Carbon registration,
onboarding event filter and keycaps, Recall popup, command list and help text
use that combination. Superapp's shortcut is unchanged. There is no persisted
custom shortcut preference to migrate; explicit registrar rebinding remains
available to its existing callers.

## Verification

- Updated default-registration expectations first; the previous code produced
  four assertion failures in the focused eight-test suite.
- After the change, all 365 parent tests, 245 onboarding tests, and 541 optimized
  Recall XCTest cases plus four Swift Testing cases pass. These runs also build
  their native app targets, using explicit minimal environments and two jobs.
- The existing onboarding Skip test now exercises the actual skip method and
  verifies that it unlocks Continue without claiming practice succeeded.
- Independent review found no actionable issue in the default, event filter,
  active shortcut references or unchanged registrar lifecycle.
- Release-contract checks pass 230/230. An initial preflight stopped because
  the minimal tool path omitted `rg`; adding its installed directory to that
  explicit path resolved the tooling preflight without changing a check.

This proves source behavior and compilation, not physical keyboard delivery.
Another application can still own Control–Shift–Space. The parent also owns
the global shortcut while onboarding uses a local event monitor; that
interaction still requires live qualification. Skip and the menu entry remain
available, and local practice is not presented as global-registration proof.

No installed app, owner setting, Superapp source or public release changed.
The preserved private `2f4293c` signed candidate does **not** contain this new
shortcut; a fresh complete candidate is required before installing this change.
The installed `f4f7bf1` app still uses its previous shortcut. Live keyboard,
Whisper insertion, Screen Recording and OCR visual checks remain pending.
