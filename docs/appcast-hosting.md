# Sparkle Appcast Hosting Recipe

How to host the Hippocampus `appcast.xml` and DMG so Sparkle auto-update works
end-to-end. This is the runbook the owner follows once per release.

The two scripts referenced below are:

- `scripts/sparkle-keygen.sh`  — mint the EdDSA signing keypair (one-time).
- `scripts/sparkle-publish.sh` — sign a DMG and add its `<item>` to `appcast.xml` (per release).

> **Trust model in one sentence.** The Hippocampus binary inside `Hippocampus.app`
> contains the Ed25519 PUBLIC key (`SUPublicEDKey` in Info.plist). Every
> `appcast.xml` `<item>` that the app fetches must carry a `sparkle:edSignature`
> minted by the matching PRIVATE key. The hosting layer can be a completely
> untrusted CDN — if it serves a tampered DMG or a tampered appcast, Sparkle
> rejects it. That is why GitHub Pages, a static and free-tier surface, is
> sufficient for integrity: confidentiality is not what we're protecting.

## End-to-end flow

```
  ┌─────────────────────────────┐         ┌──────────────────────────────┐
  │  owner laptop (1Password)   │         │  GitHub                       │
  │  ~/.hippocampus-sparkle-    │         │                              │
  │     private.key  (0600)     │         │  ┌──────────────────────┐   │
  │                             │         │  │ amyjainberkeley/hippo-    │   │
  │  1. sparkle-keygen.sh       │ ──────▶ │  │ campus  (this repo)  │   │
  │     (one-time)              │  pub    │  │  · Info.plist        │   │
  │  2. build-installer.sh      │  key    │  │    SUPublicEDKey     │   │
  │  3. sparkle-publish.sh      │         │  │  · GitHub Releases   │   │
  │      ──signs DMG──▶ sig     │ ──DMG─▶ │  │    hosts the .dmg    │   │
  │      ──writes──▶ appcast    │         │  └──────────────────────┘   │
  │                             │         │                              │
  │                             │         │  ┌──────────────────────┐   │
  │  4. push appcast.xml ──────────────▶ │  │ amyjainberkeley/hippocampus-      │   │
  │                             │  to    │  │ appcast  (Pages)     │   │
  │                             │ branch │  │  · appcast.xml only  │   │
  │                             │publish/│  └──────────┬───────────┘   │
  │                             │   *    │             │ CNAME         │
  └─────────────────────────────┘         │             ▼               │
                                          │   appcast.hippocampus.ai    │
                                          └──────────────────────────────┘
                                                       │
                                                       ▼
                                            ┌──────────────────────┐
                                            │  Hippocampus.app on  │
                                            │  user's Mac          │
                                            │  · SUFeedURL fetches │
                                            │    appcast.xml       │
                                            │  · verifies sig with │
                                            │    SUPublicEDKey     │
                                            │  · downloads DMG     │
                                            │  · verifies sig again│
                                            └──────────────────────┘
```

The private key never leaves the owner's machine + 1Password.

## Step 0 — Mint the keypair (one-time)

```bash
./scripts/sparkle-keygen.sh
```

This refuses to overwrite an existing `~/.hippocampus-sparkle-private.key`. It
prints the **public** key. Paste it into `apps/hippocampus/Resources/Info.plist`:

```xml
<key>SUPublicEDKey</key>
<string>XRC6iJSDpOpPuA78CqB0vC6Lw1YUyZalLIXgyBCfG00=</string>
```

Back up the private key file to 1Password — see the header comment of
`sparkle-keygen.sh` for the exact `op document create` command.

> **Why the script writes to a file instead of the Keychain.** macOS Keychain
> couples the key to the user's login session. We want the key to be portable
> (1Password, HSM, owner's offline backup) and inspectable (`stat` the perms).

## Step 1 — Build + sign the DMG

```bash
./scripts/build-installer.sh
# → dist/Hippocampus-1.0.0.dmg  (codesigned + notarized)
```

`build-installer.sh` produces a signed, notarized DMG. It does **not** touch
Sparkle — that's the next step.

## Step 2 — Sign the appcast item + update `appcast.xml`

```bash
./scripts/sparkle-publish.sh \
    --dmg dist/Hippocampus-1.0.0.dmg \
    --private-key ~/.hippocampus-sparkle-private.key \
    --release-notes RELEASE_NOTES_1.0.0.md
```

This:

1. Reads the private key from disk (NOT from an env var; reduces leak surface).
2. Calls Sparkle's `sign_update` to produce the Ed25519 signature over the DMG.
3. Adds or **replaces** the `<item>` for this version in `dist/appcast.xml`.
   (Idempotent: re-running on the same DMG replaces, never duplicates.)
4. Embeds the release notes inline (CDATA-escaped) so no second hosting hop
   is required for notes.

The default `<enclosure url>` points at the GitHub Releases asset URL — see
Step 3.

## Step 3 — Publish the DMG on GitHub Releases

GitHub Releases hosts large binary assets for free and does not count against
the GitHub Pages bandwidth quota. This is why we split: appcast on Pages,
DMG on Releases.

```bash
# Create the release + upload the DMG asset
gh release create v1.0.0 \
    --repo amyjainberkeley/hippocampus \
    --notes-file RELEASE_NOTES_1.0.0.md \
    --title "Hippocampus 1.0.0" \
    dist/Hippocampus-1.0.0.dmg

# Verify the asset URL matches what sparkle-publish.sh embedded
# (default shape: https://github.com/amyjainberkeley/hippocampus/releases/download/v1.0.0/Hippocampus-1.0.0.dmg)
gh release view v1.0.0 --repo amyjainberkeley/hippocampus
```

If the URL shape differs from `sparkle-publish.sh`'s default, re-run publish
with `--download-url` set to the URL `gh release view` printed; the appcast
must match the actual asset URL exactly.

## Step 4 — Publish `appcast.xml` to `amyjainberkeley/hippocampus-appcast` (Pages)

### One-time setup of the appcast repo

1. **Create the repo.** Public is simplest (free Pages on every plan):
   ```bash
   gh repo create amyjainberkeley/hippocampus-appcast \
       --public \
       --description "Hippocampus Sparkle appcast feed" \
       --clone
   cd mci-appcast
   ```

   If you require it to be private, the repo's organization needs a paid
   GitHub plan to enable Pages on a private repo. (Free orgs can only
   serve Pages from public repos.)

2. **Layout — appcast.xml at repo root.**
   ```bash
   mkdir -p .github/workflows
   touch appcast.xml index.html
   echo '<!doctype html><meta charset=utf-8><title>Hippocampus Appcast</title><p>Programmatic feed at <a href="/appcast.xml">/appcast.xml</a>.' > index.html
   git add . && git commit -m "init"
   git push -u origin main
   ```

3. **Enable Pages.** Repo Settings → Pages:
   - Source: **Deploy from a branch**
   - Branch: **main** / root (`/`)
   - (Pages auto-deploys on every push to `main` for the chosen branch.)

4. **Custom domain (recommended).** Pages settings → Custom domain:
   `appcast.hippocampus.ai`. Add the CNAME record in your DNS provider:

   ```
   appcast.hippocampus.ai.   CNAME   amyjainberkeley.github.io.
   ```

   Wait for GitHub's TLS provisioning to complete (typically <10 min).
   Then check "Enforce HTTPS" in Pages settings — Sparkle requires HTTPS.

5. **Wire the app to the custom domain.** In
   `apps/hippocampus/Resources/Info.plist`:

   ```xml
   <key>SUFeedURL</key>
   <string>https://appcast.hippocampus.ai/appcast.xml</string>
   ```

   Using the custom domain (not `*.github.io`) means a future change of
   hosting — e.g. S3 + CloudFront once volume grows — does not require a
   new app build with a new SUFeedURL.

### Per-release publish (after Step 2)

```bash
# In the main repo (this one):
git checkout -b publish/1.0.0
cp dist/appcast.xml /path/to/mci-appcast/appcast.xml

cd /path/to/mci-appcast
git checkout main && git pull
cp /path/to/dist/appcast.xml ./appcast.xml
git add appcast.xml
git commit -m "release: Hippocampus 1.0.0"
git push origin main
```

GitHub Pages picks up the change on its next deploy (typically <2 min). Verify:

```bash
curl -sSI https://appcast.hippocampus.ai/appcast.xml | head -3
# HTTP/2 200
# content-type: application/xml
# ...
```

### Optional CI: automate the mirror step

If you want `appcast.xml` to publish itself whenever a `publish/*` branch lands
in this repo, drop a workflow into `amyjainberkeley/hippocampus-appcast`. Place this in
`.github/workflows/publish.yml` of the mci-appcast repo (NOT this repo — keeping
the workflow there means this repo's `main` never holds a personal access
token):

```yaml
name: Publish appcast
on:
  repository_dispatch:
    types: [appcast-publish]
  push:
    branches: [main]
jobs:
  noop:
    # Pages auto-deploys on push to main. This job is just here so a
    # repository_dispatch from the main hippocampus repo can also nudge
    # a re-deploy if appcast.xml hasn't actually changed (e.g. CDN reset).
    runs-on: ubuntu-latest
    steps:
      - run: echo "Pages will deploy main automatically."
```

The signing is intentionally **not** in CI — the private key never enters a
GitHub Actions runner. Signing happens on the owner's Mac in Step 2, and CI
only ships the already-signed `appcast.xml`.

## Step 5 — Verify the round-trip

After Steps 3 and 4:

```bash
# Confirm the appcast is reachable and validates
curl -sS https://appcast.hippocampus.ai/appcast.xml | xmllint --noout - && echo OK

# Confirm the DMG referenced inside it is reachable + matches the recorded length
DMG_URL=$(curl -sS https://appcast.hippocampus.ai/appcast.xml \
    | grep -o 'enclosure url="[^"]*"' | head -1 | sed 's/enclosure url="//;s/"$//')
EXPECTED=$(curl -sS https://appcast.hippocampus.ai/appcast.xml \
    | grep -o 'length="[^"]*"' | head -1 | sed 's/length="//;s/"$//')
ACTUAL=$(curl -sSI "$DMG_URL" | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tr -d '\r')
[[ "$EXPECTED" == "$ACTUAL" ]] && echo "DMG length matches ($ACTUAL bytes)" || echo "MISMATCH"
```

Then in the app: **Hippocampus → Check for Updates…**. Sparkle should detect
the new version, fetch the DMG, verify both signatures, and offer to install.

## Clock skew + appcast freshness

Sparkle does not enforce a freshness window on `<pubDate>` — but the GH Pages
CDN does cache `appcast.xml` for a short period (typically 10 minutes). Two
implications:

1. If you publish 1.0.1 immediately after 1.0.0, expect up to 10 min before
   first users see it. This is fine for Hippocampus' weekly-ish cadence.
2. Do not rely on `<pubDate>` for "is this a stale feed" checks; rely on
   `sparkle:version` (the build number) which strictly monotonically
   increases.

## Key rotation

If the private key is ever exposed (lost laptop, accidental paste into a chat,
1Password vault compromise):

1. `sparkle-keygen.sh` refuses to overwrite — so move the old key aside first:
   ```bash
   mv ~/.hippocampus-sparkle-private.key{,.OLD-$(date +%Y%m%d)}
   ./scripts/sparkle-keygen.sh
   ```
2. Paste the **new** public key into `Info.plist` `SUPublicEDKey`.
3. Ship a fresh, **manually-distributed** DMG with the new public key. Existing
   installs CAN'T auto-upgrade across this boundary (intentional — the old
   public key cannot verify items signed by the new private key). Email
   dogfooders a one-time direct DMG link.
4. After every existing install has moved to a DMG carrying the new public
   key, delete the old private key from 1Password.

> A rotation event is a launch-blocker-grade outage for existing users. Keep
> the working private key copy on **one** machine and rely on 1Password as the
> single backup of record.

## Option B (later, when volume warrants): S3 + CloudFront

GitHub Pages is sufficient for the first ~50 dogfood users and well past that
(public Pages bandwidth limit is 100 GB/mo soft). Migrate to S3 + CloudFront
only when one of the following becomes true:

- Bandwidth or analytics demands (Pages gives no access logs).
- Need for fine-grained cache invalidation per release.
- A future requirement to colocate the DMG + appcast on the same origin
  (some corporate proxies whitelist by exact origin).

### Setup (one-time)

1. Create S3 bucket `hippocampus-releases` (us-east-1 or closest region):
   ```bash
   aws s3 mb s3://hippocampus-releases --region us-east-1
   ```

2. Enable static website hosting:
   ```bash
   aws s3 website s3://hippocampus-releases --index-document index.html
   ```

3. Bucket policy — public read for appcast + DMGs:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": "*",
       "Action": "s3:GetObject",
       "Resource": "arn:aws:s3:::hippocampus-releases/*"
     }]
   }
   ```

4. CloudFront distribution:
   - Origin: `hippocampus-releases.s3.amazonaws.com`
   - HTTPS only (Sparkle requires HTTPS).
   - Custom domain: `appcast.hippocampus.ai` (same CNAME as Option A — point
     it at CloudFront instead of `amyjainberkeley.github.io`).
   - ACM cert for `appcast.hippocampus.ai`.
   - Default TTL: 300s (appcast should propagate fast).

5. DNS: CNAME `appcast.hippocampus.ai` → CloudFront distribution domain.

### Per-release publish

```bash
./scripts/sparkle-publish.sh \
    --dmg dist/Hippocampus-1.0.1.dmg \
    --private-key ~/.hippocampus-sparkle-private.key \
    --release-notes RELEASE_NOTES_1.0.1.md \
    --hosting-mode s3

aws s3 cp dist/Hippocampus-1.0.1.dmg s3://hippocampus-releases/ \
    --content-type application/octet-stream

aws s3 cp dist/appcast.xml s3://hippocampus-releases/ \
    --content-type application/xml \
    --cache-control "max-age=300"

aws cloudfront create-invalidation \
    --distribution-id EXXXXXXXX \
    --paths "/appcast.xml"
```

`Info.plist` `SUFeedURL` stays `https://appcast.hippocampus.ai/appcast.xml` —
the migration is entirely DNS-level.

## Recommendation

**Start with Option A (GitHub Pages + GH Releases).** Zero infra, free,
HTTPS by default. Migrate to Option B only when one of the triggers above
fires. The CNAME-based `appcast.hippocampus.ai` makes that migration a DNS
change, not a binary change.

## No analytics

The appcast does not include `sparkle:phasedRolloutInterval`, system
profiling endpoints, or download counters. This is intentional — Hippocampus
does not phone home. `SUEnableSystemProfiling` is `false` in Info.plist.

## Appendix — appcast.xml shape

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Hippocampus Changelog</title>
        <link>https://hippocampus.ai</link>
        <description>Hippocampus app updates</description>
        <language>en</language>
        <item>
            <title>Hippocampus 1.0.0</title>
            <pubDate>Wed, 21 May 2026 12:00:00 +0000</pubDate>
            <sparkle:version>42</sparkle:version>
            <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[
            (release notes — markdown or HTML)
            ]]></description>
            <enclosure url="https://github.com/amyjainberkeley/hippocampus/releases/download/v1.0.0/Hippocampus-1.0.0.dmg"
                       sparkle:edSignature="BASE64_SIGNATURE_HERE"
                       length="52428800"
                       type="application/octet-stream" />
        </item>
    </channel>
</rss>
```

- `sparkle:version` = `CFBundleVersion` (build number, monotonic).
- `sparkle:shortVersionString` = `CFBundleShortVersionString` (display).
- `sparkle:edSignature` = Ed25519 signature from `sign_update`.
- `length` = exact byte count of the DMG.
- `sparkle:minimumSystemVersion` = matches `LSMinimumSystemVersion` in `Info.plist`.

Sparkle selects the eligible item with the highest `sparkle:version` (build
number) regardless of document order; `sparkle-publish.sh` writes the most
recently published item at the top of the channel as a readability convention
only.
