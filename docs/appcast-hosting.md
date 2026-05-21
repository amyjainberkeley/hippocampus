# Sparkle Appcast Hosting Recipe

How to host the Hippocampus appcast.xml + DMG so Sparkle auto-update works end-to-end.

## Option A: GitHub Pages (recommended for early stage)

Zero cost. Appcast + DMG served from a `gh-pages` branch on a dedicated repo.

### Setup (one-time)

1. Create repo `amyjainberkeley/hippocampus-appcast` (public or private — GitHub Pages works with both on Pro/Team plans).

2. Create an orphan `gh-pages` branch:
   ```bash
   git clone git@github.com:amyjainberkeley/hippocampus-appcast.git
   cd hippocampus-appcast
   git checkout --orphan gh-pages
   git rm -rf . 2>/dev/null || true
   echo "Hippocampus appcast" > index.html
   git add index.html && git commit -m "init gh-pages"
   git push -u origin gh-pages
   ```

3. Enable GitHub Pages in repo Settings → Pages → Source: `gh-pages` branch, root `/`.

4. URL becomes: `https://amyjainberkeley.github.io/hippocampus-appcast/appcast.xml`

### Publishing a release

After `build-installer.sh` produces `dist/Hippocampus-<version>.dmg`:

```bash
# Sign + generate appcast
SPARKLE_PRIVATE_KEY="$SPARKLE_PRIVATE_KEY" \
  ./scripts/publish-appcast.sh --hosting-mode ghpages

# Clone appcast repo, copy artifacts, push
APPCAST_REPO=$(mktemp -d)
git clone --branch gh-pages --single-branch \
  git@github.com:amyjainberkeley/hippocampus-appcast.git "$APPCAST_REPO"

cp dist/appcast.xml "$APPCAST_REPO/"
cp dist/Hippocampus-*.dmg "$APPCAST_REPO/"

cd "$APPCAST_REPO"
git add -A
git commit -m "release: Hippocampus $(cat ../dist/appcast.xml | grep shortVersionString | head -1 | sed 's/.*>\(.*\)<.*/\1/')"
git push origin gh-pages
```

The release workflow automates this (see below).

### Info.plist configuration

```xml
<key>SUFeedURL</key>
<string>https://amyjainberkeley.github.io/hippocampus-appcast/appcast.xml</string>
```

## Option B: S3 + CloudFront (production scale)

For higher bandwidth, CDN caching, download analytics, and custom domain.

### Setup (one-time)

1. Create S3 bucket `hippocampus-releases` (us-east-1 or closest region):
   ```bash
   aws s3 mb s3://hippocampus-releases --region us-east-1
   ```

2. Enable static website hosting:
   ```bash
   aws s3 website s3://hippocampus-releases \
     --index-document index.html
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

4. Create CloudFront distribution:
   - Origin: `hippocampus-releases.s3.amazonaws.com`
   - HTTPS only (Sparkle requires HTTPS)
   - Custom domain: `releases.hippocampus.ai`
   - ACM certificate for `releases.hippocampus.ai`
   - Default TTL: 300s (5 min — appcast should propagate fast)

5. DNS: CNAME `releases.hippocampus.ai` → CloudFront distribution domain.

### Publishing a release

```bash
SPARKLE_PRIVATE_KEY="$SPARKLE_PRIVATE_KEY" \
  ./scripts/publish-appcast.sh --hosting-mode s3

aws s3 cp dist/Hippocampus-*.dmg s3://hippocampus-releases/ \
  --content-type application/octet-stream

aws s3 cp dist/appcast.xml s3://hippocampus-releases/ \
  --content-type application/xml \
  --cache-control "max-age=300"

# Invalidate CloudFront cache for appcast
aws cloudfront create-invalidation \
  --distribution-id EXXXXXXXX \
  --paths "/appcast.xml"
```

### Info.plist configuration

```xml
<key>SUFeedURL</key>
<string>https://releases.hippocampus.ai/appcast.xml</string>
```

## Recommendation

**Use Option A (GitHub Pages) now.** Zero cost, zero infra, automatic HTTPS. Adequate for early users and beta testing. Migrate to Option B when download volume or custom-domain branding matters.

## Sparkle EdDSA Key Management

### Generate keys (one-time)

Sparkle 2.x uses Ed25519 (EdDSA). Generate a keypair:

```bash
# From a Sparkle 2.x checkout or framework bundle:
./bin/generate_keys

# Outputs:
#   Private key (base64): <PRIVATE_KEY>
#   Public key (base64):  <PUBLIC_KEY>
```

### Private key

- Store as GitHub Actions secret: `SPARKLE_PRIVATE_KEY`
- NEVER commit to the repo
- NEVER log in CI output
- Back up securely (losing it = no more signed updates for existing installs)

### Public key

Set in `apps/hippocampus/Resources/Info.plist`:

```xml
<key>SUPublicEDKey</key>
<string>XRC6iJSDpOpPuA78CqB0vC6Lw1YUyZalLIXgyBCfG00=</string>
```

This is the base64-encoded Ed25519 public key. Sparkle verifies every update against this before installing. Changing it breaks updates for existing installs.

### Key rotation

If the private key is compromised:
1. Generate new keypair
2. Ship a manually-distributed release with the new `SUPublicEDKey`
3. Users who installed via the old key must re-download manually (one-time)
4. Update `SPARKLE_PRIVATE_KEY` secret in GitHub Actions

## Appcast XML format

Each release is an `<item>` in the RSS feed:

```xml
<item>
    <title>Hippocampus 1.0.0</title>
    <pubDate>Wed, 21 May 2026 12:00:00 +0000</pubDate>
    <sparkle:version>42</sparkle:version>
    <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <enclosure url="https://example.com/Hippocampus-1.0.0.dmg"
               sparkle:edSignature="BASE64_SIGNATURE_HERE"
               length="52428800"
               type="application/octet-stream" />
</item>
```

- `sparkle:version` = `CFBundleVersion` (build number, monotonically increasing)
- `sparkle:shortVersionString` = `CFBundleShortVersionString` (display version)
- `sparkle:edSignature` = Ed25519 signature from `sign_update`
- `length` = exact byte count of the DMG
- `sparkle:minimumSystemVersion` = matches `LSMinimumSystemVersion` in Info.plist

## No analytics

The appcast does not include `sparkle:phasedRolloutInterval`, system profiling endpoints, or download counters. This is intentional — Hippocampus does not phone home. `SUEnableSystemProfiling` is `false` in Info.plist.
