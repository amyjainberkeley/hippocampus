# Hippocampus Repository Instructions

## Canonical Source And Publication

The owner requests versioned GitHub publication at every completed update.
The canonical repository is https://github.com/amyjainberkeley/hippocampus.
Do not publish new work to the archived landing/demo repositories.

- Inspect the worktree and remotes before editing or publishing. Preserve
  unrelated edits and never include local memory, real capture output, keys,
  certificates, tokens, or environment files in commits.
- Commit each coherent, verified checkpoint with a meaningful message. Push it
  to the active work branch on the canonical repository before closing the task.
  If a checkpoint is incomplete, say so in its status and use a draft PR rather
  than presenting it as release-ready.
- Verify the remote branch SHA after pushing and report its commit/PR link.
  Do not claim publication from a local commit or a successful local build.
- Update the existing PR for the branch; do not create duplicate PRs. Keep
  `main` and release tags unchanged unless integration/release is authorized.
  Never force-push or rewrite published history without explicit approval.
- Desktop code and website source belong in this repository. Website source
  lives in `website/`; preserve its separate package lockfile and hosting ID.
  The earlier standalone Sites checkout is deployment history, not a second
  untracked source of new product changes.
- GitHub source publication, website deployment/access, local installation,
  and public signed-binary releases are separate states. Keep them explicit.
  Source-push authorization does not waive installer qualification or authorize
  uploading private user data. Follow the Sites hosting skill for deployment.

`docs/STATUS.md` is canonical product/release truth. Keep its baseline current
when product code changes. Read `docs/PUBLISHING.md` for source locations,
publication boundaries and the initial history audit.

## Test Environment Hygiene

Run builds and tests with a minimal, explicitly constructed environment. Do not
pass provider API keys or unrelated service credentials into test processes.
Subprocess fixtures must set their own allowlisted environment rather than
inherit the agent's environment. Diagnostic output must never print environment
values. Keep local diagnostic files private and outside the product source tree.
