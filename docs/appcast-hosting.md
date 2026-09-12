# Sparkle Release And Appcast Runbook

This is the canonical Hippocampus update topology:

- GitHub Releases hosts the signed, notarized DMG and SHA-256 sidecar.
- GitHub Pages for this repository hosts only `appcast.xml`.
- `SUFeedURL` is
  `https://amyjainberkeley.github.io/hippocampus/appcast.xml`.
- A tag creates an inspectable draft. It does not publish the release or feed.
- The separate `Publish inspected release and appcast` workflow promotes the
  draft, then deploys the inspected appcast.

There is no Vercel release dependency and no sibling appcast repository.

## Trust Boundaries

Apple Developer ID and notarization establish the downloaded application's
publisher and distribution integrity. Sparkle's Ed25519 signature binds the DMG
bytes referenced by the appcast to `SUPublicEDKey` in the installed app.
GitHub hosting is therefore a delivery surface, not a signing authority.

The tag workflow verifies all of the following before it creates a draft:

1. Tag, bundle version, build number, changelog, DMG filename, checksum,
   appcast item, status audit, tag-owned model manifest, minimum macOS version,
   and GitHub Releases URL agree.
2. The Sparkle private key derives the `SUPublicEDKey` committed in
   `Info.plist`, and that public key verifies the appcast signature over the
   exact DMG bytes.
3. The app and outer DMG pass signing, notarization-staple, and Gatekeeper
   checks.
4. All required model bundles came from one immutable archive with the
   configured SHA-256 and pass structural checks.

## One-Time Owner Setup

1. Complete [Owner Signing Setup](release/OWNER_SIGNING.md).
2. In repository Settings > Pages, choose **GitHub Actions** as the source.
3. Create protected `release-signing` and `github-pages` environments. Require
   owner review, prevent self-review, disable bypass where available, and
   restrict the signing environment to release tags.
4. Provision the immutable model archive and commit its URL/digest in
   `release-models.json` as described in `OWNER_SIGNING.md`.
5. Confirm `SUPublicEDKey` matches the CI secret without exposing either key:

   ```bash
   ./scripts/verify-sparkle-keypair.sh \
     --private-key ~/.hippocampus-sparkle-private.key \
     --info-plist apps/hippocampus/Resources/Info.plist
   ```

The Pages URL returns 404 until the first successful publication. Do not point a
shipped binary at another feed to hide that setup gap.

## Stage A Draft

Create the exact version tag only after the blocking release checklist passes:

```bash
git tag v0.1.0
git push origin v0.1.0
```

`.github/workflows/release.yml` performs a clean-history build, reconstructs
models, builds every Rust and Swift binary, signs and notarizes the app and DMG,
signs the appcast item, verifies the full identity, and creates a **draft**
GitHub release containing:

- `Hippocampus-<version>.dmg`
- `Hippocampus-<version>.dmg.sha256`
- `appcast.xml`
- `notary-app-{submission,log}.json`
- `notary-dmg-{submission,log}.json`

No public update feed changes during this workflow.

## Inspect

Before publication:

1. Review the generated release notes and Apple notary log.
2. Download the draft DMG and verify its sidecar.
3. Mount it on a second Mac, drag the app to Applications, launch it from a
   quarantined download, and run the clean-install and upgrade smoke tests.
4. Inspect `appcast.xml`; its enclosure must point to the same tag and DMG
   name in this repository's GitHub Releases URL.
5. Confirm the Keychain-held database key and capture preference survive an
   upgrade from the prior public version.

Do not replace draft assets after inspection. Rebuild from a new commit and tag
when bytes change.

## Stage B Publish

Run **Publish inspected release and appcast** from GitHub Actions with:

- `tag`: the exact inspected draft tag.
- `confirmation`: `PUBLISH`.

The workflow:

1. Requires the named release to exist; it records whether it is still a draft.
2. Downloads and independently re-verifies its checksum, identity, DMG
   Sparkle signature, notarization staple, and Gatekeeper assessment.
3. Uploads the appcast as a private Pages deployment artifact.
4. Promotes the GitHub release only when it is still a draft.
5. Deploys `appcast.xml` only after promotion succeeds.

That ordering means Sparkle never sees an update whose download asset is still
private. If Pages fails after promotion, rerunning the same confirmed workflow
reverifies the immutable public assets and resumes only the Pages deployment.

## Verify Public State

```bash
curl --fail --silent --show-error \
  https://amyjainberkeley.github.io/hippocampus/appcast.xml \
  | xmllint --noout -

gh release view v0.1.0 --repo amyjainberkeley/hippocampus
```

The appcast has no system-profile reporting, analytics endpoint, or download
counter. `SUEnableSystemProfiling` remains false.

## Key Rotation

Sparkle key rotation is a compatibility migration, not a routine secret edit.
Follow Sparkle's documented rotation rules: ship a bridge update signed by the
old trusted key that changes only the Sparkle key, then use the new key for
later updates. Never rotate the Developer ID identity and Sparkle key in the
same bridge release.

Primary references:

- [Sparkle documentation](https://sparkle-project.org/documentation/)
- [GitHub Pages custom workflows](https://docs.github.com/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)
- [GitHub deployment environments](https://docs.github.com/actions/reference/workflows-and-actions/deployments-and-environments)
- [Apple code signing in depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
