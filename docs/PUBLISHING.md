# Source, Versions, And Publication

## One GitHub Home

Canonical repository: [amyjainberkeley/hippocampus](https://github.com/amyjainberkeley/hippocampus).

The September 7 publication uses `codex/hippocampus-v1`, with a pull request
against `main`. A branch push preserves every commit; it does not merge that
branch or create a public installer release. The previous remote main was
`e1e067c`, 254 desktop commits behind `7b1fc0d`.

| Surface | Source / Version |
| --- | --- |
| Desktop app and memory engine | `apps/`, `adapters/`, `core/`, `extensions/` |
| Product website | `website/` |
| Exact change history | GitHub branch commits and the integration PR |
| Built/proven/missing ledger | `docs/STATUS.md` and `docs/audit/2026-09-06-owner-product-ledger.md` |
| Installed owner app at publication | `/Applications/Hippocampus.app`, source `224466d` |
| Private website deployment | https://hippocampus-memory.amyjain.chatgpt.site, version 1, source `e50f448` |

The local desktop checkout is
`/Users/amy/hippo-work/hippocampus/.worktrees/hippocampus-v1`.
The earlier website checkout is `/Users/amy/hippocampus-website`. Its original
commit is preserved as a merge parent in the combined GitHub history. At import,
the `website/` tree exactly matches its original tree:
`c06dd658988abf408adb573ef54739a811f78d05`.
Future website work belongs in `website/`; retain the existing Sites project ID
and export a website-rooted source revision for Sites when deploying. Do not
create a replacement Site or upload the whole desktop repository as a web app.

## Every Update

1. Review the diff and run the checks appropriate to the changed surface.
2. Record what changed, what passed, and remaining failures in versioned docs.
3. Inspect outgoing commits for credentials and unintended private content.
4. Commit coherent changes and push the current work branch to `origin`.
5. Verify GitHub has that exact SHA; maintain its existing pull request.
6. Report the GitHub link and separately say whether the installed app, website
   deployment, public audience or downloadable binary changed.

Do not wait for another owner request to push completed checkpoints. Do not
auto-commit unknown dirty files, force-push history, or pretend that unverified
work is finished. A failing or incomplete checkpoint belongs on a clearly
labeled draft branch/PR, not in a release announcement.

## Publication Audit: September 7

Gitleaks 8.30.1 was fetched from the upstream GitHub release. Its archive hash
matched the release API digest and checksum:
`b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5`.
The 254 outgoing desktop commits produced four alerts, all inspected in their
original commits:

| Commit | Location | Finding |
| --- | --- | --- |
| `0c8e157` | `apps/agent/tests/client_registry.rs:128` | Repeated fixed hexadecimal test fixture, not a live key |
| `358629d` | `CaptureConsentAuthorityTests.swift:107` | Fabricated App Group identifier |
| `a821f65` | `KeyWrapAuditTests.swift:64` | Fixed synthetic key bytes for a fake Keychain client |
| `c3fe931` | `ProcessSupervisor.swift:39` | Swift `KeychainKeyStore.storageModel` symbol, not a credential |

The original website commit scan returned zero alerts. No memory database,
certificate, DMG, environment file, or real-capture archive is included. Tracked
evaluation corpora declare synthetic provenance; the site's screenshot is the
synthetic test document. This is a scoped publication check, not a guarantee
that the whole application has no security defects.

The unrelated modified task report and untracked Python cache remain local and
are not included in this publication.

## Release Boundaries

Source history is public because the canonical GitHub repository is public.
The website remains owner-only until its audience change is approved. Public
installer releases remain subject to the actual gates in `docs/STATUS.md`,
including model/license packaging and installation/update qualification.
No release tag, automatic update, public DMG, permission reset, or user-memory
upload is part of this source publication.
