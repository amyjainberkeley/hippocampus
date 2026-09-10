# Installer And Update Experience

## Observed Failure

Finder refused to replace Hippocampus because the installed bundle was in use.
Closing Recall had not stopped the menu-bar parent, capture helper or writer.
Independent coding-client MCP processes also referenced the installed bundle.
Their existence is not permission to terminate the user's coding clients.

The installed provenance remained `fe90a3d`, not the `fb73f77` candidate. Several
private installers shared the same filename, making name-only selection in
Spotlight unreliable. The old installation had not been replaced or migrated
at this checkpoint.

## Design Changes

The app, menu bar, extension icons and volume icon now share a simple brain
mark. One light background replaces the nested H tiles. The editable SVGs
retain matching geometry; the menu-bar version uses transparent openings and
the system template tint. Existing product colors and native UI are unchanged.

The installer now uses a 640x420 layout and a matching 144-dpi background,
deliberate icon positions, a quiet update instruction and accessible legal terms.
It generates and reads back Finder metadata without UI scripting. Missing layout
is fatal. A private mountpoint prevents a build from detaching other installers;
a failed detach preserves that build's backing image rather than deleting it.

The parent quit gate previously rejected a standard core/quit Apple event unless
the product menu had already latched intent. It now recognizes that event
synchronously and uses the existing awaited supervisor shutdown. Nil or unrelated
events remain blocked, and an explicit restart retains precedence. This corrects
source handling; a live Finder/Sparkle upgrade is a separate test.

## Verification At This Checkpoint

- The new visual-asset regression failed against the old mark, then passed
  after rendering all icon sizes. It checks consistent geometry, frame count,
  PNG dimensions, transparency and the excluded mint palette.
- All 11 optimized `MCIDesignSystemTests` pass.
- Eight new quit-gate tests pass after an expected RED failure. The full optimized
  parent suite passes 342 cases; the AppKit adapter and gate were reviewed.
- Eleven installer-layout tests pass, including a synthetic HFS+ image converted
  to read-only and remounted at a different path. Nine runtime/cleanup checks,
  two brand checks, the legal contract, 230 release-contract assertions and 16
  release-safety tests pass.
- The atomic bundle-swap helper passes 20 synthetic tests, including actual
  open-descriptor/mmap preservation, kernel refusal, cross-device rejection and
  repeat-call rejection. Review caught a same-HEAD retry that could swap back;
  it was reproduced RED and fixed by rejecting equal expected heads before I/O.
- Swift/Recall executable compilation succeeds. This is not a new capture or
  retrieval-quality qualification.
- `git diff --check` passes for the current changes.

## Installation Boundary

Use the [owner upgrade procedure](../release/OWNER_UPGRADE_2026-09-09.md).
The old parent only supports verified shutdown through its explicit Quit action.
Automated inspection of that menu timed out, so the owner was asked to choose
Quit. Do not replace a running writer, force a permission reset or remove locks.

Once writers are stopped, preserve a consistent encrypted recovery copy before
launching schema-10 code. Old read-only MCP processes may retain old executable
mappings; a same-filesystem whole-bundle swap can preserve those mappings while
new launches use the new bundle. This does not qualify old clients against the
new schema or authorize running old mutation code afterward.

The existing hosted OCR failures, screen-only proof, actual client qualification
and second-Mac checks remain open. Branding, signing and notarization do not
close those gates.

## Build Dependencies

Only the packaging environment adds `ds-store==1.3.3` and `mac-alias==2.2.3`.
Their MIT upstreams and PyPI wheel hashes are recorded in
`scripts/installer-requirements.txt`. Provisioning uses an isolated environment,
binary wheels and required hashes; the installer does not install dependencies
automatically. Neither package is included in the application. The app's runtime
dependencies, capture permissions and data-sharing policy are unchanged.
