# docs/decisions/BEST_PRACTICES.md

Subtree invariants for the ADR archive. Read the top-level
`BEST_PRACTICES.md` first; this file adds ADR-discipline rules.

## Purpose

ADRs are the append-only provenance record for every locked
material decision in MCI. They are cited by name across `DESIGN.md`,
research memos, and PR bodies, so filename and numbering are load-
bearing. Rules below preserve that stability.

## Rules

1. **Sequential numbering, allocated on merge.** Filenames are
   `NNNN-kebab-slug.md`, zero-padded to 4 digits, monotonically
   increasing. Check `ls docs/decisions/ | tail -1` BEFORE
   claiming the next number; if two branches race, the second-
   merging renumbers before landing.

2. **One decision per file.** An ADR captures one locked material
   choice. If a document argues two independent decisions, split
   it into two ADRs. This keeps citation chains unambiguous.

3. **Never rewrite a merged ADR.** Once merged, the body is
   immutable. To change a decision, write a new ADR and append a
   "Superseded by ADR-NNNN" line to the old one — the only edit
   allowed on a shipped ADR.

4. **Ratification path is explicit.** Every ADR names its
   ratifier: CEO for commercial / product-scope decisions, CSO
   for crypto / sync / capture / compliance, CTO for
   architecture. Unratified drafts stay out of `docs/decisions/`
   (park in `docs/research/` as a memo until ratified).

5. **Load-bearing sections.** Each ADR MUST include: Context,
   Decision, Consequences, and Ratifier. "Alternatives
   considered" is strongly encouraged so future agents don't
   relitigate settled forks.

6. **Cite research provenance.** Every ADR that consumes a
   research memo names it (path + date). If no memo exists, the
   ADR body itself must contain the analysis — never merge an
   ADR that reads "as discussed in gbrain."

## Common mistakes

- Claiming a number on draft and racing another branch —
  duplicate `0036-*.md` files. Allocate on merge, not on branch.
- Editing the body of a merged ADR to fix a typo instead of
  filing an erratum. The archive stops being append-only.
- Merging a draft that lacks a Ratifier line — later readers
  cannot tell if the decision is locked or still fluid.
- Splitting a decision across two "half-ADRs" that only make
  sense together. Merge them or keep them as one.

## Reference chain

- `../../BEST_PRACTICES.md` — MCI-wide invariants (root).
- `./README.md` — archive map and naming rules.
- `../DESIGN.md` — the canonical architecture ADRs feed into.
- `../research/BEST_PRACTICES.md` — sibling memo discipline.
