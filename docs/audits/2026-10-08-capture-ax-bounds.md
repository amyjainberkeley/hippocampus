# Live capture stored nothing after 2026-09-14: the accessibility backstop

## Evidence

On the owner Mac, `capture-status.json` reported `last_stored_frame_at`
2026-09-14T06:10:55Z and `suppression_reason: failsafe-unknown` on 2026-10-08.
In ten minutes of ordinary use the helper delivered 1,411 frames, suppressed
1,299, and 997 of those were `failsafe-unknown`. Its content-free health lines
named the cause:

```
ax_unclassified focus_result=0 focused=present subrole_result=-25212
value_hidden=negative identifier=negative descendant=error
descendant_reason=depth-limit descendant_depth=3 descendant_visited=3
descendant_ancestor_link=true
```

The focused element was present and not secure (no subrole, value not
hidden, no password-like identifier). The descendant backstop, which looks for
a secure text field nested under a focused container, followed the element's
`AXFocusedUIElement` link back to itself three times, reached its depth bound
and reported an error. An error makes the §4 answer "unknown", and the cascade
suppresses unknown frames. Deep but finite trees (web areas, Electron apps)
ended the same way through the node bound.

## Change (owner-approved 2026-10-08)

In both bounded traversals (descendant subrole and identifier keywords):

- A node already visited is skipped. Its subrole was already checked; a
  revisit can add nothing.
- Reaching the depth, node or per-node child bound ends the search with
  "nothing secure found within the bound" (`.negative`) instead of `.errored`.
- A failed or malformed accessibility read still yields `.errored`, and a
  malformed child entry now outranks an over-long array so it cannot be masked.

## What still protects password entry

The descendant backstop was a third line of defence. Still in force, in cascade
order: the built-in and owner denylists (password managers, Keychain Access,
System Settings, SecurityAgent, sign-in and banking sites, private-window
titles); OS-blacked regions; process-wide Secure Event Input, which macOS turns
on while any secure field has focus; the focused element's own secure subrole;
the value-hidden and identifier checks on the focused element; the bounded
descendant search itself; and, after recognition, the secret and one-time-code
scan on both the raw and the stored text. A password field also renders as
mask glyphs.

## Tests

Six tests that pinned "bound or cycle means unknown" now pin the new outcome
while keeping their read bounds; new tests cover the self-referencing focus
link seen live, children past the per-node limit, and a malformed entry inside
an over-long array. All 89 accessibility and cascade tests pass.
