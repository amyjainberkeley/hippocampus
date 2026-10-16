#!/usr/bin/env bash
set -euo pipefail

if ! command -v rg >/dev/null 2>&1; then
    printf 'FATAL: release contract checking requires ripgrep (rg).\n' >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE="$REPO_ROOT/.github/workflows/release.yml"
PUBLISH="$REPO_ROOT/.github/workflows/publish-release.yml"
CARGO="$REPO_ROOT/.github/workflows/cargo.yml"
SWIFT_CI="$REPO_ROOT/.github/workflows/swift.yml"
CHECK="$REPO_ROOT/scripts/check.sh"
INFO_PLIST="$REPO_ROOT/apps/hippocampus/Resources/Info.plist"
RELEASE_CI="$REPO_ROOT/.github/workflows/release-contract.yml"
INSTALLER="$REPO_ROOT/scripts/build-installer.sh"
BUILD_APP="$REPO_ROOT/apps/hippocampus/Resources/build-app.sh"
CAPTURE_HELPER_MAIN="$REPO_ROOT/adapters/macos/MCICaptureHelper/Sources/MCICaptureHelper/main.swift"
BRIEF_PRESENCE="$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/BriefModelPresence.swift"
STATUS_MENU="$REPO_ROOT/apps/hippocampus/Sources/Hippocampus/StatusMenuView.swift"
HIPPOCAMPUS_APP="$REPO_ROOT/apps/hippocampus/Sources/Hippocampus/HippocampusApp.swift"
APP_MODELS="$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/Resources/models.json"
ONBOARDING_SCREENS="$REPO_ROOT/apps/onboarding/Sources/Onboarding"
CONVERT_EMBEDDER="$REPO_ROOT/scripts/convert_embedder.py"
CONVERT_NER="$REPO_ROOT/scripts/convert_ner.py"
CONVERT_BRIEF="$REPO_ROOT/scripts/convert_brief_model.py"
PREFERENCES="$REPO_ROOT/apps/hippocampus/Sources/Hippocampus/PreferencesWindow.swift"
NOTICE="$REPO_ROOT/NOTICE"
TOML_LICENSE_TEST="$REPO_ROOT/scripts/test-toml-license-contract.sh"
TOML_LICENSE_VERIFIER="$REPO_ROOT/scripts/verify-toml-license-contract.py"
STAGE_RECALL_FFI="$REPO_ROOT/scripts/stage-recall-ffi.sh"
E2E="$REPO_ROOT/scripts/e2e-clean-home.sh"
E2E_CONTRACT="$REPO_ROOT/scripts/test-e2e-clean-home-contract.sh"
APP_GROUP_CONTRACT_TEST="$REPO_ROOT/scripts/test-app-group-contract.sh"
RELEASE_SCRIPT="$REPO_ROOT/scripts/release-0.3.0.sh"
SPARKLE_PUBLISH="$REPO_ROOT/scripts/sparkle-publish.sh"
IDENTITY="$REPO_ROOT/scripts/verify_release_identity.py"
FEED_URL='https://github.com/amyjainberkeley/hippocampus/releases/latest/download/appcast.xml'
CARGO_TOML="$REPO_ROOT/Cargo.toml"

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
require_literal "$RELEASE" 'scripts/build-provenance.py verify' \
    'release workflow verifies provenance on the mounted final app'
require_literal "$RELEASE" '--expected-source-head "$(git rev-parse HEAD)"' \
    'release provenance is bound to the release checkout HEAD'
require_literal "$RELEASE" '--expected-source-digest "$(python3 scripts/product-source-digest.py --repo-root .)"' \
    'release provenance is bound to the release checkout source digest'
require_pattern "$RELEASE" 'scripts/sparkle-publish\.sh' \
    'release workflow signs the Sparkle appcast'
require_literal "$RELEASE" '--private-key "$RUNNER_TEMP/sparkle-private.key"' \
    'release workflow signs the appcast with the verified Sparkle key file'
if [[ -e "$REPO_ROOT/scripts/publish-appcast.sh" ]]; then
    fail 'one appcast writer: the env-key publish-appcast.sh is gone'
else
    pass 'one appcast writer: the env-key publish-appcast.sh is gone'
fi
require_pattern "$RELEASE" 'fetch-depth:[[:space:]]*0' \
    'release checkout includes full history for status provenance'
require_literal "$RELEASE" 'MACOSX_DEPLOYMENT_TARGET: "14.0"' \
    'release workflow pins Rust binaries to the supported macOS 14 deployment target'
for package in apps/hippocampus adapters/macos/MCICaptureHelper apps/recall-ui apps/onboarding apps/mind; do
    require_literal "$RELEASE" "--package-path $package" \
        "release workflow builds ${package}"
done
require_pattern "$RELEASE" 'scripts/prepare-release-models\.sh' \
    'release workflow reconstructs and validates model inputs'
require_literal "$RELEASE" 'MCI_REQUIRE_COREML_QUALITY: "1"' \
    'release workflow makes the Core ML runtime quality gate fail closed'
require_literal "$RELEASE" 'cargo test --locked -p mci-embed-coreml --test quality -- --nocapture' \
    'release workflow runs the 50-sentence Core ML runtime quality gate'
require_pattern "$RELEASE" 'scripts/release_models_manifest\.py' \
    'release workflow reads the tag-owned model manifest'
require_literal "$RELEASE" '--manifest release-models.json' \
    'release workflow binds model inputs to the committed manifest'
reject_pattern "$RELEASE" 'vars\.RELEASE_MODELS_(URL|SHA256)' \
    'release model identity cannot drift through mutable repository variables'
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
require_pattern "$PUBLISH" 'name:[[:space:]]*release-publish' \
    'publication uses its own protected environment, without signing secrets'
reject_pattern "$PUBLISH" 'pages|Pages' \
    'publication needs no GitHub Pages site: the release carries the feed'
require_pattern "$PUBLISH" 'gh release edit.*--draft=false --latest' \
    'publication promotes the inspected draft to Latest, which is the feed'
require_literal "$PUBLISH" 'releases/latest/download/appcast.xml' \
    'publication confirms the public feed serves the inspected appcast'
require_pattern "$PUBLISH" 'scripts/verify-release-identity\.sh --phase staged' \
    'publication re-verifies downloaded release identity'
require_order "$PUBLISH" 'scripts/verify-release-identity\.sh --phase staged' 'gh release edit.*--draft=false' \
    'publication re-verifies the draft before promoting it'
require_order "$PUBLISH" 'gh release edit.*--draft=false' 'cmp published-appcast\.xml inspected/appcast\.xml' \
    'publication checks the live feed only after promotion'
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

require_literal "$INFO_PLIST" "<string>$FEED_URL</string>" \
    'shipped Sparkle feed is the latest GitHub release appcast'
require_literal "$IDENTITY" "FEED_URL = \"$FEED_URL\"" \
    'the release identity gate pins the same feed'
for feed_file in "$INFO_PLIST" "$IDENTITY" "$SPARKLE_PUBLISH" "$RELEASE_SCRIPT" "$PUBLISH" "$RELEASE"; do
    reject_pattern "$feed_file" 'github\.io|hippocampus\.ai' \
        "$(basename "$feed_file") names neither a Pages feed nor the parked hippocampus.ai domain"
done
require_literal "$SPARKLE_PUBLISH" '"$SIGN_UPDATE" -f "$KEY_PATH" "$TMP_APPCAST"' \
    'sparkle-publish signs the appcast itself with sign_update'
require_literal "$SPARKLE_PUBLISH" '"$SIGN_UPDATE" --verify -f "$KEY_PATH" "$TMP_APPCAST"' \
    'sparkle-publish verifies the signed appcast before writing it'
require_literal "$SPARKLE_PUBLISH" 'sparkle:format="markdown"' \
    'sparkle-publish marks Markdown notes the way Sparkle reads them'
require_literal "$IDENTITY" 'validate_feed_signature(appcast, identity["public_key"])' \
    'the staged identity gate verifies the feed signature with SUPublicEDKey'
require_pattern "$RELEASE_SCRIPT" 'verify-sparkle-keypair\.sh' \
    'release preflight checks the Sparkle key against SUPublicEDKey'
require_literal "$RELEASE_SCRIPT" '"$REPO_ROOT/scripts/sparkle-publish.sh"' \
    'release script writes the appcast with sparkle-publish'
require_literal "$RELEASE_SCRIPT" '--dmg "$DMG" --private-key "$SPARKLE_KEY" --changelog-notes' \
    'release script signs the notarized DMG with the Sparkle key file'
require_literal "$RELEASE_SCRIPT" 'identity.validate_staged(root, tag, found, dmg, appcast, repository)' \
    'release script runs the staged identity gate on its appcast'
require_order "$RELEASE_SCRIPT" '^verify_release$' '^make_appcast$' \
    'release script signs the appcast only for a verified DMG'
require_literal "$RELEASE_SCRIPT" 'UPLOADS=("$DMG" "$DMG.sha256" "$STABLE_DMG" "$STABLE_DMG.sha256" "$APPCAST")' \
    'release script lists appcast.xml with the DMGs to upload'
require_literal "$RELEASE_SCRIPT" 'say "    ./update-cask.sh \"$DMG\""' \
    'release script says how to point the Homebrew cask at the notarized DMG'
PRIVATE_REPORTING='https://github.com/amyjainberkeley/hippocampus/security/advisories/new'
for contact_file in "$REPO_ROOT/SECURITY.md" "$REPO_ROOT/docs/legal/terms-of-service.md" \
    "$REPO_ROOT/assets/installer/EULA.rtf"; do
    require_literal "$contact_file" "$PRIVATE_REPORTING" \
        "$(basename "$contact_file") sends private reports to GitHub private reporting"
    reject_pattern "$contact_file" '@hippocampus\.ai|//hippocampus\.ai' \
        "$(basename "$contact_file") names no address on the parked hippocampus.ai domain"
done
require_literal "$INSTALLER" '-volname "Hippocampus" \' \
    'the disk image volume is named Hippocampus, with no commit in it'
reject_pattern "$INSTALLER" 'build-note|SOURCE_HEAD:0:|SOURCE_DIGEST:0:' \
    'nothing a downloader sees carries a build number, commit or source digest'
require_literal "$INSTALLER" 'STABLE_DMG="$DIST_DIR/Hippocampus.dmg"' \
    'the installer also writes Hippocampus.dmg for releases/latest/download'

# Size cuts that change no behaviour: LZMA disk image, thin LTO, and binaries
# without local symbols (dSYMs kept).
if rg -Uq '^\[profile\.release\]\nlto = "thin"\nstrip = "symbols"\n' "$CARGO_TOML"; then
    pass 'release Rust binaries use thin LTO and are stripped of local symbols'
else
    fail 'release Rust binaries use thin LTO and are stripped of local symbols'
fi
require_literal "$INSTALLER" 'DMG_FORMAT="ULMO"' \
    'the disk image is LZMA-compressed (ULMO)'
require_literal "$INSTALLER" '-format "$DMG_FORMAT"' \
    'the finished disk image is converted to that format'
reject_pattern "$INSTALLER" 'UDZO|zlib-level' \
    'no zlib disk image remains'
require_literal "$RELEASE_SCRIPT" '"$REPO_ROOT/scripts/strip-release-binaries.sh" --symbols-dir "$SYMBOLS_DIR"' \
    'release script strips its binaries and keeps their dSYMs'
require_order "$RELEASE_SCRIPT" 'strip-release-binaries\.sh" --symbols-dir' '^assemble_app\(\) \{' \
    'release script strips before it assembles, signs and records provenance'
require_literal "$RELEASE" 'scripts/strip-release-binaries.sh --symbols-dir "$RUNNER_TEMP/symbols"' \
    'tag workflow strips its binaries and keeps their dSYMs'
require_order "$RELEASE" 'name: Build all binaries' 'scripts/strip-release-binaries\.sh' \
    'tag workflow strips what it built'
require_order "$RELEASE" 'scripts/strip-release-binaries\.sh' 'name: Build signed and notarized DMG' \
    'tag workflow strips before it assembles and signs'
require_pattern "$CHECK" 'strip-release-binaries\|bash\|test\|scripts/test-strip-release-binaries\.sh' \
    'the unified local gate runs the strip fixture'

# Launch gates D1 and D2: the same app checks in the release script and the
# tag workflow, syspolicy_check, and clean notary logs.
APP_GATE="$REPO_ROOT/scripts/verify-release-app.sh"
require_literal "$APP_GATE" 'refuse "hippocampus-mind links FoundationModels as ${LINK:-nothing}, not weakly' \
    'the app gate refuses a mind that does not weak-link FoundationModels'
require_literal "$RELEASE_SCRIPT" 'clean_env "$REPO_ROOT/scripts/verify-release-app.sh" --version "$RELEASE_VERSION"' \
    'release script checks its app with the shared app gate'
require_literal "$RELEASE_SCRIPT" 'check_assembled_app "$app" "$GATEKEEPER_CHECK"' \
    'release script runs syspolicy_check on the app in the DMG'
require_literal "$RELEASE_SCRIPT" '    GATEKEEPER_CHECK="distribution"' \
    'the release itself checks the app in the DMG with syspolicy_check distribution'

# The dry run: built and signed here, never notarized, stamped, committed or
# opened, and never what a release workflow runs.
require_literal "$RELEASE_SCRIPT" '--dry-run) DRY_RUN=1; shift ;;' \
    'release script has a dry-run mode'
require_literal "$RELEASE_SCRIPT" 'ASSEMBLY_MODE=(--release-dry-run)' \
    'a dry run assembles without the STATUS audit and without opening the app'
require_literal "$RELEASE_SCRIPT" 'INSTALLER_MODE=(--dry-run)' \
    'a dry run packages the DMG without notarizing it or opening the app'
require_literal "$RELEASE_SCRIPT" 'GATEKEEPER_CHECK="notary-submission"' \
    'a dry run checks the app the way the notary service would'
require_literal "$RELEASE_SCRIPT" 'say "== docs/STATUS.md not stamped and nothing committed (dry run)"' \
    'a dry run stamps and commits nothing'
require_literal "$RELEASE_SCRIPT" 'say "DRY RUN: nothing was notarized, stamped, committed, pushed, tagged or uploaded,"' \
    'a dry run says what it did not do'
require_literal "$BUILD_APP" '--release-dry-run) RELEASE_DRY_RUN=1; shift ;;' \
    'app assembly has a release dry-run mode'
require_literal "$BUILD_APP" '=== Launch-verify gate: SKIPPED for a release dry run; this app was never opened ===' \
    'a release dry run never opens the app it assembles'
require_literal "$BUILD_APP" '"--release-dry-run is a release build signed with Developer ID"' \
    'a release dry run cannot be combined with debug or ad-hoc assembly'
require_literal "$INSTALLER" '--dry-run) DRY_RUN=1; shift ;;' \
    'the installer has a dry-run mode'
require_literal "$INSTALLER" 'FATAL: --dry-run is a release build signed with a Developer ID identity' \
    'an installer dry run is a Developer ID release build'
require_literal "$INSTALLER" 'Notarization: skipped (dry run: nothing is sent to Apple'"'"'s notary service)' \
    'an installer dry run sends nothing to the notary service'
for workflow in "$RELEASE" "$PUBLISH" "$RELEASE_CI"; do
    reject_pattern "$workflow" '--(release-)?dry-run' \
        "$(basename "$workflow") never runs a dry run"
done
for log_name in app dmg; do
    require_literal "$RELEASE_SCRIPT" "\"\$DIST_DIR/notary-$log_name-log.json\"" \
        "release script requires a clean $log_name notary log"
    require_literal "$RELEASE" "dist/notary-$log_name-log.json" \
        "tag workflow requires a clean $log_name notary log"
done
require_literal "$RELEASE" 'scripts/verify-release-app.sh --version "${GITHUB_REF_NAME#v}" --team "$RELEASE_TEAM_ID"' \
    'tag workflow checks the mounted app with the shared app gate'
require_literal "$RELEASE" '--minimum-macos 14.0 --gatekeeper distribution "$MOUNT/Hippocampus.app"' \
    'tag workflow runs syspolicy_check distribution on the mounted app'
require_literal "$INSTALLER" 'python3 "$CHECK_NOTARY_LOG" --archive "$(basename "$artifact")" "$log"' \
    'installer refuses an accepted submission whose log lists issues'
require_literal "$INSTALLER" 'FATAL: syspolicy_check is missing; a release must pass syspolicy_check distribution' \
    'installer refuses to ship a release without syspolicy_check'
require_pattern "$CHECK" 'release-app-gate\|bash\|test\|scripts/test-verify-release-app\.sh' \
    'the unified local gate runs the app gate fixtures'
require_pattern "$CHECK" 'notary-log-contract\|bash\|test\|python3 -B scripts/test_check_notary_log\.py' \
    'the unified local gate runs the notary log fixtures'

# The one-line installer takes the latest release by its fixed asset name,
# with no GitHub API call, and is tested against a local fake release.
INSTALL_SH="$REPO_ROOT/scripts/install.sh"
require_literal "$INSTALL_SH" 'BASE="$RELEASES/latest/download"' \
    'install.sh downloads the latest release by its fixed asset name'
reject_pattern "$INSTALL_SH" 'api\.github\.com' \
    'install.sh needs no rate-limited GitHub API call'
require_literal "$INSTALL_SH" "--proto-redir '=https'" \
    'install.sh follows redirects only to HTTPS'
require_pattern "$CHECK" 'install-sh-fixtures\|bash\|test\|scripts/test-install-sh\.sh' \
    'the unified local gate runs the installer against a fake release'
for stable_asset in 'dist/Hippocampus.dmg' 'dist/Hippocampus.dmg.sha256'; do
    if [[ "$(rg -c -F -x "            $stable_asset" "$RELEASE" || true)" == 2 ]]; then
        pass "release workflow hands over and drafts $stable_asset"
    else
        fail "release workflow hands over and drafts $stable_asset"
    fi
done
require_pattern "$INSTALLER" 'Release installer requires notarization credentials' \
    'release installer fails closed without notarization credentials'
require_literal "$INSTALLER" 'python3 "$GENERATE_EULA" --check' \
    'release assembly fails closed on legal source or artifact drift'
require_pattern "$INSTALLER" 'codesign --timestamp --sign "\$DEVELOPER_ID" "\$FINAL_DMG"' \
    'installer signs the outer DMG with Developer ID before notarization'
require_pattern "$INSTALLER" 'codesign --verify --strict.*"\$FINAL_DMG"' \
    'installer verifies the outer DMG signature'
require_pattern "$INSTALLER" 'spctl --assess --type open --context context:primary-signature.*"\$FINAL_DMG"' \
    'installer runs the Gatekeeper disk-image assessment'
require_pattern "$INSTALLER" '--wait --output-format json' \
    'installer records structured notarization submission results'
require_literal "$STAGE_RECALL_FFI" 'export MACOSX_DEPLOYMENT_TARGET=14.0' \
    'Recall FFI staging pins native objects to the supported macOS 14 deployment target'
require_pattern "$INSTALLER" 'notarytool log' \
    'installer retrieves Apple notarization logs'
require_pattern "$INSTALLER" 'notary-\$\{label\}-submission\.json' \
    'installer retains non-secret notarization provenance'
reject_pattern "$INSTALLER" 'NOTARYTOOL_PASSWORD|NOTARY_ARGS\[\*\]|APP_NOTARY_ARGS\[\*\]' \
    'installer never accepts or renders raw notarization passwords'
require_literal "$BUILD_APP" 'QWEN3_TOKENIZER="$REPO_ROOT/models/tokenizer.json"' \
    'app assembly validates an optional Qwen tokenizer produced by conversion'
require_literal "$BUILD_APP" 'QWEN3_TOKENIZER_DEST="$QWEN3_DEST_DIR/tokenizer.json"' \
    'app assembly places an optional tokenizer beside the Qwen model'
reject_pattern "$INSTALLER" 'QWEN3_MODEL_PATH=|NER_MODEL_PATH=' \
    'optional enrichment models are not installer ship blockers'
require_literal "$BUILD_APP" 'evidence-cited extractive briefs remain active' \
    'app assembly names the no-Qwen production fallback'
require_literal "$BUILD_APP" 'Tier 1 entity extraction remains active' \
    'app assembly names the no-BERT production fallback'
require_literal "$BRIEF_PRESENCE" '.appendingPathComponent("tokenizer.json")' \
    'runtime readiness and first-launch seed include the Qwen tokenizer'
reject_pattern "$STATUS_MENU" '@State private var briefsEnabled|MCIBriefsEnabled' \
    'menu does not expose an unwired Daily Briefs toggle'
require_literal "$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/HippocampusURLRoute.swift" 'case "recall":' \
    'the day stays reachable through the hippocampus://recall route'
reject_pattern "$STATUS_MENU" 'Add Richer Brief Model|model-download' \
    'menu does not expose the unavailable Qwen download'
reject_pattern "$HIPPOCAMPUS_APP" 'Download AI Model|model-download|ModelDownloadView' \
    'app has no dead model-download window'
reject_pattern "$APP_MODELS" 'qwen3-1\.7b|huggingface\.co' \
    'shipped model manifest advertises only reachable model assets'
reject_pattern "$ONBOARDING_SCREENS" 'startDownload\(|Download \(|Daily briefs disabled|enable Daily Briefs' \
    'no onboarding screen offers a model download'
reject_pattern "$PREFERENCES" 'Ollama endpoint \(optional\)|ollamaEndpoint' \
    'preferences do not expose the unwired Ollama endpoint'
require_literal "$CONVERT_EMBEDDER" 'MODEL_REVISION = "e596f507467533e48a2e17c007f0e1dacc837b33"' \
    'embedder conversion pins the reviewed upstream revision'
require_literal "$CONVERT_NER" 'DEFAULT_MODEL = "dslim/bert-base-NER"' \
    'NER reconstruction builds the bundle the release names'
require_literal "$CONVERT_NER" 'DEFAULT_REVISION = "d1a3e8f13f8c3566299d95fcfc9a8d2382a9affc"' \
    'NER conversion pins the reviewed upstream revision'
require_literal "$CONVERT_BRIEF" 'MODEL_REVISION = "70d244cc86ccca08cf5af4e1e306ecf908b1ad5e"' \
    'brief-model conversion pins the reviewed upstream revision'
require_literal "$BUILD_APP" 'NOTICE_SRC="$REPO_ROOT/NOTICE"' \
    'app assembly treats third-party notices as a release input'
require_literal "$BUILD_APP" 'python3 "$TOML_LICENSE_VERIFIER" --repo-root "$REPO_ROOT"' \
    'app assembly runs the pinned TOML license-content gate'
require_literal "$BUILD_APP" 'cp "$NOTICE_SRC" "$RESOURCES/NOTICE.txt"' \
    'app assembly bundles third-party notices for offline access'
require_order "$BUILD_APP" 'python3 "\$TOML_LICENSE_VERIFIER"' 'cp "\$NOTICE_SRC"' \
    'license content is verified before the offline notice is bundled'
require_order "$BUILD_APP" 'cp "\$NOTICE_SRC"' 'codesign --verify --deep --strict' \
    'offline third-party notices are present before the app is signed'
require_literal "$PREFERENCES" 'Bundle.main.url(forResource: "NOTICE", withExtension: "txt")' \
    'About opens the bundled third-party notices without a network dependency'
reject_pattern "$PREFERENCES" 'hippocampus-swart\.vercel\.app/licenses' \
    'About does not point license disclosure at an unshipped 404 page'
reject_pattern "$NOTICE" 'imposes no condition' \
    'model notice does not make an unverified Reuters derivative-rights conclusion'
require_pattern "$CHECK" 'release-contract\|bash\|lint\|scripts/test-release-contract\.sh' \
    'the unified local gate runs the release contract'
require_pattern "$CHECK" 'app-group-contract\|bash\|test\|scripts/test-app-group-contract\.sh' \
    'the unified local gate runs the App Group identity contract'
require_pattern "$CHECK" 'toml-license-contract\|bash\|lint\|scripts/test-toml-license-contract\.sh' \
    'the unified local gate runs the TOML dependency license contract'
require_pattern "$CHECK" 'retention-policy-contract\|bash\|test\|scripts/test-retention-policy-contract\.sh' \
    'the unified local gate runs the picker-to-worker retention contract'
require_pattern "$CHECK" 'clean-home-contract\|bash\|lint\|scripts/test-e2e-clean-home-contract\.sh' \
    'the unified local gate enforces the clean-home product contract'
require_pattern "$CHECK" 'swift-test-hippocampus\|swift\|test\|scripts/swift-package\.sh test --package-path apps/hippocampus' \
    'the unified local gate runs the app supervisor and capture-consent tests'
require_literal "$SWIFT_CI" 'swift test --package-path apps/hippocampus' \
    'Swift CI runs the Hippocampus app tests'
require_literal "$SWIFT_CI" 'swift test --package-path apps/onboarding' \
    'Swift CI runs the onboarding tests'
require_literal "$SWIFT_CI" 'swift test --package-path apps/mind' \
    'Swift CI runs the hippocampus-mind tests'
require_literal "$SWIFT_CI" 'apps/mind/scripts/test-without-foundation-models.sh' \
    'Swift CI proves hippocampus-mind builds and passes without Foundation Models'
require_literal "$SWIFT_CI" "'apps/mind/**'" \
    'Swift CI runs when hippocampus-mind changes'
require_literal "$SWIFT_CI" 'swift test --package-path adapters/macos/MCIKeyframeCodec' \
    'Swift CI runs the keyframe codec tests'
require_literal "$RELEASE_CI" 'scripts/swift-package.sh run --package-path apps/hippocampus CaptureConsentBehavior' \
    'release CI executes the capture-consent behavior fixture'
require_literal "$RELEASE_CI" 'scripts/swift-package.sh run --package-path apps/hippocampus ChildProcessEnvironmentBehavior' \
    'release CI proves prepared file-key authority reaches supervised children'
require_literal "$RELEASE_CI" 'scripts/swift-package.sh run --package-path adapters/macos/MCICaptureHelper HelperReadinessBehavior' \
    'release CI proves readiness publication is private, atomic, and add-only'
require_literal "$RELEASE_CI" 'scripts/swift-package.sh run --package-path apps/onboarding OnboardingRouteBehavior' \
    'release CI executes the durable app-access route fixture'
for script in test-release-contract.sh test-app-group-contract.sh test-release-identity.sh \
    test-prepare-release-models.sh test-release-model-manifest.sh \
    test-sparkle-keygen.sh test-sparkle-keypair.sh test-sparkle-publish.sh \
    test-strip-release-binaries.sh test-verify-release-app.sh test_check_notary_log.py \
    test-install-sh.sh; do
    require_literal "$RELEASE_CI" "scripts/$script" \
        "release CI runs $script"
done
require_literal "$RELEASE_CI" "SPARKLE_PUBLISH_TEST_REQUIRE_TOOLS: '1'" \
    'release CI fails the appcast test, never skips it, without Sparkle tools'
require_pattern "$CHECK" 'sparkle-publish-fixtures\|bash\|test\|__sparkle_publish_lane' \
    'the unified local gate runs the appcast test'
require_literal "$RELEASE_CI" 'scripts/test-task-2-product-truth.sh' \
    'release CI runs the legal drift and product-truth contract'
require_literal "$RELEASE_CI" 'scripts/test-onboarding-product-truth.sh' \
    'release CI runs the onboarding consent-claims contract'
require_literal "$RELEASE_CI" 'scripts/test-retention-policy-contract.sh' \
    'release CI runs the picker-to-worker retention contract'
require_literal "$RELEASE_CI" 'scripts/test-e2e-clean-home-contract.sh' \
    'release CI runs the clean-home source contract'
require_literal "$RELEASE_CI" 'scripts/test-development-file-key-contract.sh' \
    'release CI proves development file-key authority cannot ship'
require_literal "$RELEASE_CI" 'scripts/test-no-quarantine-bypass.sh' \
    'release CI proves the app does not bypass Gatekeeper quarantine'
require_literal "$RELEASE_CI" 'node --test extensions/safari/__tests__/content.test.cjs' \
    'release CI proves Safari private-context capture fails closed'
require_literal "$RELEASE_CI" 'CaptureSourcePolicyBehavior' \
    'release CI executes the browser pixel exclusion fixture'
require_literal "$RELEASE_CI" 'scripts/test-capture-overlap-corpus.sh' \
    'release CI builds and verifies the focused-window overlap corpus'
require_literal "$RELEASE_CI" 'scripts/test-live-capture-overlap-contract.sh' \
    'release CI keeps the live focused-window verifier fail-closed'
require_literal "$RELEASE_CI" 'scripts/test-product-source-provenance.sh' \
    'release CI keeps signed qualification source provenance fail-closed'
require_literal "$RELEASE_CI" 'scripts/e2e-clean-home.sh' \
    'release CI executes the clean-home product path'
require_literal "$RELEASE_CI" 'scripts/test-toml-license-contract.sh' \
    'release CI runs the TOML dependency license contract'
for release_input in .github/workflows/publish-release.yml scripts/build-installer.sh \
    apps/hippocampus/Resources/build-app.sh apps/hippocampus/Package.swift \
    apps/hippocampus/Package.resolved NOTICE \
    third_party/licenses/TOMLKit-0.6.0-LICENSE.txt \
    third_party/licenses/tomlplusplus-3.4.0-LICENSE.txt \
    third_party/licenses/toml-license-manifest.json \
    scripts/verify-toml-license-contract.py scripts/verify-models.sh \
    scripts/test-toml-license-contract.sh \
    scripts/test-retention-policy-contract.sh scripts/stage-recall-ffi.sh \
    scripts/e2e-clean-home.sh scripts/test-e2e-clean-home-contract.sh \
    scripts/test-development-file-key-contract.sh scripts/test-no-quarantine-bypass.sh \
    scripts/verify-parent-lifetime.sh \
    scripts/test-capture-overlap-corpus.sh 'tools/capture-overlap-corpus/**' \
    scripts/run-live-capture-overlap.sh scripts/test-live-capture-overlap-contract.sh \
    scripts/product-source-digest.py scripts/build-provenance.py \
    scripts/test-product-source-provenance.sh \
    'scripts/live-capture/**' \
    'core/brain/**' 'core/src/ipc/**' 'adapters/macos/mci-brain-ffi/**' \
    'adapters/macos/MCICaptureHelper/**' \
    apps/agent/src/brain_ingest.rs apps/agent/src/runner.rs \
    apps/onboarding/Package.swift \
    apps/onboarding/Sources/OnboardingKit/RetentionStore.swift \
    apps/onboarding/Sources/OnboardingKit/DiskRetentionStore.swift \
    apps/onboarding/Sources/OnboardingKit/RetentionViewModel.swift \
    apps/onboarding/Sources/Onboarding/OnboardingFlowView.swift \
    apps/onboarding/Sources/Onboarding/OnboardingApp.swift \
    apps/onboarding/Sources/OnboardingKit/OnboardingFlowViewModel.swift \
    apps/onboarding/Sources/OnboardingKit/OnboardingScreen.swift \
    apps/onboarding/Sources/OnboardingKit/OnboardingCopy.swift \
    apps/onboarding/Sources/OnboardingKit/OnboardingConsentStore.swift \
    scripts/test-onboarding-product-truth.sh \
    apps/onboarding/Tests/Fixtures/RetentionPersistenceBehavior/main.swift \
    apps/onboarding/Tests/OnboardingKitTests/DiskRetentionStoreTests.swift \
    apps/onboarding/Tests/OnboardingKitTests/RetentionViewModelTests.swift \
    apps/onboarding/Tests/OnboardingKitTests/OnboardingFlowViewModelTests.swift \
    apps/onboarding/Tests/Fixtures/OnboardingRouteBehavior/main.swift \
    apps/hippocampus/Sources/HippocampusKit/ProcessSupervisor.swift \
    apps/hippocampus/Sources/HippocampusKit/KeyCustodyCommandRunner.swift \
    apps/hippocampus/Sources/HippocampusKit/DevelopmentFileKeyMode.swift \
    apps/hippocampus/Sources/HippocampusKit/KeyStore.swift \
    apps/hippocampus/Sources/HippocampusKit/CaptureConsentAuthority.swift \
    apps/hippocampus/Sources/HippocampusKit/SafariInboxReader.swift \
    apps/hippocampus/Sources/HippocampusKit/SupervisorTransitionGate.swift \
    apps/hippocampus/Sources/HippocampusKit/SupervisorProcessRuntime.swift \
    apps/hippocampus/Sources/HippocampusKit/RuntimeConfig.swift \
    apps/hippocampus/Sources/HippocampusKit/PreferencesStore.swift \
    apps/hippocampus/Sources/HippocampusKit/MenuBarStatus.swift \
    apps/hippocampus/Sources/Hippocampus/PreferencesWindow.swift \
    apps/hippocampus/Sources/Hippocampus/StatusMenuView.swift \
    apps/hippocampus/Sources/Hippocampus/HippocampusApp.swift \
    apps/hippocampus/Tests/Fixtures/SupervisorLifecycleBehavior.swift \
    apps/hippocampus/Tests/Fixtures/CaptureConsentBehavior.swift \
    apps/hippocampus/Tests/Fixtures/ChildProcessEnvironmentBehavior.swift \
    apps/hippocampus/Tests/Fixtures/RuntimeConfigBehavior.swift \
    apps/hippocampus/Tests/Fixtures/RetentionPreferencesBehavior.swift \
    apps/hippocampus/Tests/HippocampusKitTests/ProcessSupervisorTests.swift \
    apps/hippocampus/Tests/HippocampusKitTests/KeyStoreTests.swift \
    apps/hippocampus/Tests/HippocampusKitTests/CaptureConsentAuthorityTests.swift \
    apps/hippocampus/Tests/HippocampusKitTests/SafariInboxReaderTests.swift \
    extensions/safari/appex/SafariWebExtensionHandler.swift \
    extensions/safari/content.js extensions/safari/background.js \
    extensions/safari/manifest.json extensions/safari/__tests__/content.test.cjs \
    apps/hippocampus/Tests/HippocampusKitTests/RuntimeConfigTests.swift \
    apps/hippocampus/Tests/HippocampusKitTests/PreferencesStoreTests.swift \
    apps/hippocampus/Tests/HippocampusKitTests/MenuBarQuickActionsTests.swift \
    adapters/macos/MCICaptureHelper/Package.swift \
    adapters/macos/MCICaptureHelper/Sources/MCICaptureHelper/main.swift \
    adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/HelperReadinessReceipt.swift \
    adapters/macos/MCICaptureHelper/Tests/Fixtures/HelperReadinessBehavior/main.swift \
    adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Security/KeychainDatabaseKeyResolver.swift \
    adapters/macos/MCICaptureHelper/Tests/MCICaptureHelperKitTests/KeychainDatabaseKeyResolverTests.swift \
    adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression/BrowserPixelCapturePolicy.swift \
    adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression/SuppressionCascade.swift \
    adapters/macos/MCICaptureHelper/Tests/Fixtures/CaptureSourcePolicyBehavior/main.swift \
    apps/agent/Cargo.toml apps/agent/src/retention_worker.rs \
    apps/agent/src/bin/mci_agent.rs apps/agent/src/bin/mci_e2e_fixture.rs \
    apps/agent/tests/retention_preferences_contract.rs \
    apps/hippocampus/Sources/HippocampusKit/AppGroupIdentity.swift \
    apps/hippocampus/Resources/Hippocampus.entitlements \
    extensions/safari/appex/Info.plist \
    extensions/safari/appex/HippocampusSafariExtension.entitlements \
    scripts/test-app-group-contract.sh scripts/lib/app-group-contract.sh \
    CHANGELOG.md docs/STATUS.md rust-toolchain.toml; do
    require_literal "$RELEASE_CI" "'$release_input'" \
        "release CI watches $release_input"
done

if [[ -x "$E2E" && -x "$E2E_CONTRACT" && -x "$APP_GROUP_CONTRACT_TEST" ]]; then
    pass 'clean-home and App Group contracts are committed and executable'
else
    fail 'clean-home and App Group contracts are committed and executable'
fi
require_literal "$RELEASE_CI" "'release-models.json'" \
    'release CI watches the tag-owned model manifest'
reject_pattern "$CARGO" 'continue-on-error:[[:space:]]*true' \
    'Clippy is a blocking CI gate'
require_literal "$CAPTURE_HELPER_MAIN" 'let tccStatusMonitor = TCCStatusMonitor()' \
    'capture helper constructs the live TCC monitor'
require_literal "$CAPTURE_HELPER_MAIN" 'tccStatusMonitor: tccStatusMonitor' \
    'capture helper passes the TCC monitor into the live session'

if [[ -f "$TOML_LICENSE_TEST" && -f "$TOML_LICENSE_VERIFIER" ]]; then
    pass 'TOML dependency license gate and verifier are committed'
else
    fail 'TOML dependency license gate and verifier are committed'
fi

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
