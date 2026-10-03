# Immutable retrieval model provisioning

`release-models.json` now names a real hosted archive and its exact SHA-256.
The public-release **prebuild identity check passes** for 0.2.0 instead of
rejecting `UNPROVISIONED`. This completes one build prerequisite; it does not
publish or install the desktop app.

## Published input

The dedicated [model artifact release](https://github.com/amyjainberkeley/hippocampus-models/releases/tag/v0.2.0)
contains the required Arctic Embed S Core ML model, a checksum sidecar and a
per-file receipt. Application source remains in the main Hippocampus repository.
No application tag, app installer, update feed, website or account setting was
changed by this model-only release.

| Field | Value |
| --- | --- |
| Archive | `release-models-0.2.0.tar.gz` |
| Size | 61,232,508 bytes |
| SHA-256 | `e0d9a98ef6cb793aa539b1719a4546c2de16f9c445c60fe846829928daa5a718` |
| Model repository commit | `f81da3535577bbe272e51010172fb92f4b512f09` |
| GitHub release ID | `402725696` |
| Upstream model revision | `e596f507467533e48a2e17c007f0e1dacc837b33` |

The five compiled-model/compatibility files are byte-for-byte identical to the
model in the qualified private `4983f6c` app. The archive also includes the
complete Apache-2.0 license and a notice identifying the upstream revision and
Core ML conversion. The pinned upstream
[model repository](https://huggingface.co/Snowflake/snowflake-arctic-embed-s/tree/e596f507467533e48a2e17c007f0e1dacc837b33)
declares Apache-2.0; the license text came from the
[Apache Software Foundation](https://www.apache.org/licenses/LICENSE-2.0.txt).
This is a scoped model attribution record, not an exhaustive app dependency audit.

The archive was assembled from an explicit inventory of seven files, with
sorted paths, fixed permissions/ownership and zero timestamps. It has no app
executable, private memory, credentials, Qwen or NER model. The old private
0.1.0 archive remains unchanged; its different archive digest is not relabeled.

## Verification

- Local reconstruction through the production archive verifier passed, and
  every extracted file's size and hash matched the inventory.
- All three uploaded assets matched their local sizes and GitHub-reported
  SHA-256 digests before publication.
- GitHub release immutability was enabled before publication. The published
  release reports `immutable: true`.
- An HTTPS download using an empty home, no authentication and no curl config
  returned the exact 61,232,508 bytes and expected SHA-256. Reconstruction of
  that public download passed the same model contract and all seven file hashes.
- `gh release verify-asset` verified the downloaded archive against GitHub's
  cryptographically signed release attestation.
- Model-manifest tests: 7 passed. Archive preparation tests: 8 passed, including
  wrong hashes, unsafe members and no-overwrite behavior. Release-identity tests:
  9 passed. The actual 0.2.0 prebuild identity check passes. No gates were weakened.
- The model repository metadata patch passed its secret scan with zero matches;
  its exact pushed commit was verified. Private logs remain outside Git.

An initial Python HTTPS fetch stopped because that interpreter could not locate
its local CA chain. The system curl download succeeded with normal certificate
verification; no TLS verification or system trust settings were disabled.

## Unchanged release boundaries

The original notarized `4983f6c` candidate, its source identity and its manifest
receipt remain unchanged. Its exact source still contains the historical
unprovisioned release-model manifest. A future app built/tagged from the newly
provisioned source must carry its own provenance; the earlier app is not
relabeled as this source update.

The current owner app remains `f4f7bf1`. The installer and owner upgrade are still
pending the previously reported unlock/Keychain and live-qualification steps.
No new desktop or notary retry was made during this checkpoint. Screen Recording,
physical shortcuts, onboarding, cancellation/zoom, clean-machine checks and
schema-aware recovery remain open. The known Apple Vision fallback failures and
earlier frozen-worker timeout remain recorded. Superapp is unchanged.
