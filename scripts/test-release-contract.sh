#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE="$REPO_ROOT/.github/workflows/release.yml"
PUBLISH="$REPO_ROOT/.github/workflows/publish-release.yml"
CARGO="$REPO_ROOT/.github/workflows/cargo.yml"
CHECK="$REPO_ROOT/scripts/check.sh"
INFO_PLIST="$REPO_ROOT/apps/hippocampus/Resources/Info.plist"
RELEASE_CI="$REPO_ROOT/.github/workflows/release-contract.yml"
INSTALLER="$REPO_ROOT/scripts/build-installer.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    printf 'PASS: %s\n' "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

require_pattern() {
    local file="$1" pattern="$2" message="$3"
    if rg -q -- "$pattern" "$file"; then pass "$message"; else fail "$message"; fi
}

require_literal() {
    local file="$1" literal="$2" message="$3"
    if rg -Fq -- "$literal" "$file"; then pass "$message"; else fail "$message"; fi
}

reject_pattern() {
    local file="$1" pattern="$2" message="$3"
    if rg -q -- "$pattern" "$file"; then fail "$message"; else pass "$message"; fi
}

require_order() {
    local file="$1" first="$2" second="$3" message="$4"
    local first_line second_line
    first_line=$(rg -n -- "$first" "$file" | head -1 | cut -d: -f1 || true)
    second_line=$(rg -n -- "$second" "$file" | head -1 | cut -d: -f1 || true)
    if [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]]; then
        pass "$message"
    else
        fail "$message"
    fi
}

require_pattern "$RELEASE" 'Require release secrets' \
    'release workflow has an explicit secret gate'
for name in APPLE_CERTIFICATE_P12 APPLE_CERTIFICATE_PASSWORD NOTARYTOOL_APPLE_ID \
    NOTARYTOOL_TEAM_ID NOTARYTOOL_PASSWORD SPARKLE_PRIVATE_KEY; do
    printf -v expected 'Required release secret is missing: \\$%s' "$name"
    require_literal "$RELEASE" "$expected" \
        "release workflow requires ${name}"
done
require_pattern "$RELEASE" 'check-signing-prereqs\.sh --release' \
    'release workflow runs the fail-closed signing prerequisite gate'
require_pattern "$RELEASE" 'codesign --verify --deep --strict' \
    'release workflow always verifies the app signature'
require_pattern "$RELEASE" 'xcrun stapler validate' \
    'release workflow validates the notarization staple'
require_pattern "$RELEASE" 'scripts/publish-appcast\.sh' \
    'release workflow signs the Sparkle appcast'
require_pattern "$RELEASE" 'fetch-depth:[[:space:]]*0' \
    'release checkout includes full history for status provenance'
for package in apps/hippocampus adapters/macos/MCICaptureHelper apps/recall-ui apps/onboarding; do
    require_literal "$RELEASE" "--package-path $package" \
        "release workflow builds ${package}"
done
require_pattern "$RELEASE" 'scripts/prepare-release-models\.sh' \
    'release workflow reconstructs and validates model inputs'
for name in RELEASE_MODELS_URL RELEASE_MODELS_SHA256; do
    printf -v expected 'Required release variable is missing: \\$%s' "$name"
    require_literal "$RELEASE" "$expected" \
        "release workflow requires ${name}"
done
require_pattern "$RELEASE" 'scripts/verify-release-identity\.sh --phase prebuild' \
    'release workflow freezes tag, bundle, changelog, and feed identity before building'
require_pattern "$RELEASE" 'scripts/verify-release-identity\.sh --phase staged' \
    'release workflow verifies the staged DMG and appcast identity'
require_pattern "$RELEASE" 'scripts/verify-sparkle-keypair\.sh' \
    'release workflow verifies the Sparkle private/public key pair'
reject_pattern "$RELEASE" 'DMG will be ad-hoc signed|skipping appcast publish|if: env\.APPLE_CERTIFICATE_P12|if: env\.NOTARYTOOL_APPLE_ID|if: steps\.sparkle' \
    'release workflow has no optional signing or update-signing path'
reject_pattern "$RELEASE" 'build-installer\.sh --skip-build' \
    'release workflow assembles the app before packaging the DMG'
reject_pattern "$RELEASE" 'Deploy appcast|deploy-pages|git push origin gh-pages|gh release edit.*--draft=false' \
    'tag workflow cannot publish artifacts before owner inspection'
require_pattern "$RELEASE" 'draft:[[:space:]]*true' \
    'tag workflow creates a draft release'
reject_pattern "$RELEASE" '[+][[:space:]]{2,}' \
    'tag workflow shell commands contain no patch-marker argument corruption'
require_pattern "$RELEASE" 'name:[[:space:]]*release-signing' \
    'secret-bearing signing job uses the protected release-signing environment'
require_pattern "$RELEASE" 'persist-credentials:[[:space:]]*false' \
    'secret-bearing checkout does not persist a write credential'
require_pattern "$RELEASE" 'actions/upload-artifact@[0-9a-f]{40}' \
    'signing job hands verified artifacts to a separate draft job'
require_pattern "$RELEASE" 'actions/download-artifact@[0-9a-f]{40}' \
    'draft job consumes only verified artifacts'
reject_pattern "$RELEASE" 'uses:[[:space:]]+[^#[:space:]]+@(v[0-9]+|stable)([[:space:]]|$)' \
    'secret-bearing workflow pins every action to a full commit SHA'

require_pattern "$PUBLISH" 'workflow_dispatch:' \
    'publication is an explicit owner-triggered workflow'
require_pattern "$PUBLISH" 'environment:[[:space:]]*$' \
    'publication uses a protected GitHub environment'
require_pattern "$PUBLISH" 'name:[[:space:]]*github-pages' \
    'publication uses the GitHub Pages environment'
require_pattern "$PUBLISH" 'actions/deploy-pages@' \
    'publication deploys the inspected appcast through GitHub Pages'
require_pattern "$PUBLISH" 'gh release edit.*--draft=false' \
    'publication promotes the inspected draft release'
require_pattern "$PUBLISH" 'scripts/verify-release-identity\.sh --phase staged' \
    'publication re-verifies downloaded release identity'
require_order "$PUBLISH" 'gh release edit.*--draft=false' 'actions/deploy-pages@' \
    'publication promotes the release before exposing the appcast'
require_pattern "$PUBLISH" "if:[[:space:]]+steps\\.release-state\\.outputs\\.is_draft == 'true'" \
    'publication promotes only while the inspected release is still a draft'
reject_pattern "$PUBLISH" 'test "\$\(gh release view.*isDraft.*\)" = true' \
    'publication can resume Pages deployment after an already-promoted release'
reject_pattern "$PUBLISH" 'hippocampus-appcast|APPCAST_REPO_TOKEN|git push' \
    'publication has no sibling-repository credential dependency'
reject_pattern "$PUBLISH" '[+][[:space:]]{2,}' \
    'publication shell commands contain no patch-marker argument corruption'
require_pattern "$PUBLISH" 'persist-credentials:[[:space:]]*false' \
    'publication checkout does not persist a write credential'
reject_pattern "$PUBLISH" 'uses:[[:space:]]+[^#[:space:]]+@v[0-9]+([[:space:]]|$)' \
    'publication workflow pins every action to a full commit SHA'

require_pattern "$INFO_PLIST" 'https://amyjainberkeley\.github\.io/hippocampus/appcast\.xml' \
    'shipped Sparkle feed matches the publication target'
require_pattern "$INSTALLER" 'Release installer requires notarization credentials' \
    'release installer fails closed without notarization credentials'
require_pattern "$INSTALLER" 'codesign --timestamp --sign "\$DEVELOPER_ID" "\$FINAL_DMG"' \
    'installer signs the outer DMG with Developer ID before notarization'
require_pattern "$INSTALLER" 'codesign --verify --strict.*"\$FINAL_DMG"' \
    'installer verifies the outer DMG signature'
require_pattern "$INSTALLER" 'spctl --assess --type open --context context:primary-signature.*"\$FINAL_DMG"' \
    'installer runs the Gatekeeper disk-image assessment'
require_pattern "$INSTALLER" '--wait --output-format json' \
    'installer records structured notarization submission results'
require_pattern "$INSTALLER" 'notarytool log' \
    'installer retrieves Apple notarization logs'
require_pattern "$INSTALLER" 'notary-\$\{label\}-submission\.json' \
    'installer retains non-secret notarization provenance'
reject_pattern "$INSTALLER" 'NOTARYTOOL_PASSWORD|NOTARY_ARGS\[\*\]|APP_NOTARY_ARGS\[\*\]' \
    'installer never accepts or renders raw notarization passwords'
require_pattern "$CHECK" 'release-contract\|bash\|lint\|scripts/test-release-contract\.sh' \
    'the unified local gate runs the release contract'
for script in test-release-contract.sh test-release-identity.sh \
    test-prepare-release-models.sh test-sparkle-keygen.sh test-sparkle-keypair.sh; do
    require_literal "$RELEASE_CI" "scripts/$script" \
        "release CI runs $script"
done
for release_input in .github/workflows/publish-release.yml scripts/build-installer.sh \
    apps/hippocampus/Resources/build-app.sh apps/hippocampus/Package.resolved \
    CHANGELOG.md docs/STATUS.md rust-toolchain.toml; do
    require_literal "$RELEASE_CI" "'$release_input'" \
        "release CI watches $release_input"
done
reject_pattern "$CARGO" 'continue-on-error:[[:space:]]*true' \
    'Clippy is a blocking CI gate'

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
