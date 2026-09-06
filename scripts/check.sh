#!/usr/bin/env bash
# check.sh — unified local lint+test gate for MCI. See `./scripts/check.sh --help`.
# Cycle 8.44 runlog architecture study §1 — adopted pattern:
# continue-on-failure per lane + PASS/FAIL summary + selector filtering.

set -euo pipefail

# ---- Repo root ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ---- Colors (TTY only) -------------------------------------------------------
if [[ -t 1 ]]; then
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
    C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

QUIET="${CHECK_SH_QUIET:-0}"

# ---- Lane catalog ------------------------------------------------------------
# Each lane row: name | family | action | command
# (command executed verbatim via `bash -c`)
LANES=(
    "rust-fmt|rust|fmt|cargo fmt --check --all"
    "rust-clippy|rust|lint|cargo clippy --workspace --all-targets"
    "rust-test|rust|test|cargo test --workspace"
    "rust-audit|rust|audit|python3 scripts/audit-supply-chain.py"
    "swift-fmt|swift|fmt|__swift_fmt_lane"
    "swift-package-wrapper|swift|test|scripts/test-swift-package.sh"
    "swift-test-helper|swift|test|scripts/swift-package.sh test --package-path adapters/macos/MCICaptureHelper"
    "swift-test-recall-ui|swift|test|scripts/swift-package.sh test --package-path apps/recall-ui"
    "swift-test-onboarding|swift|test|scripts/swift-package.sh test --package-path apps/onboarding"
    "swift-test-hippocampus|swift|test|scripts/swift-package.sh test --package-path apps/hippocampus"
    "recall-state-behavior|swift|test|scripts/swift-package.sh run --package-path apps/recall-ui RecallStateBehavior"
    "recall-refresh-behavior|swift|test|scripts/swift-package.sh run --package-path apps/recall-ui MemoryRefreshBehavior"
    "context-handoff-behavior|swift|test|scripts/swift-package.sh run --package-path apps/recall-ui ContextHandoffBehavior"
    "onboarding-ai-connector|swift|test|scripts/swift-package.sh run --package-path apps/onboarding AIToolConnectorBehavior"
    "menu-ai-connector|swift|test|scripts/swift-package.sh run --package-path apps/hippocampus AIToolConnectorBehavior"
    "capture-consent-behavior|swift|test|scripts/swift-package.sh run --package-path apps/hippocampus CaptureConsentBehavior"
    "child-process-environment|swift|test|scripts/swift-package.sh run --package-path apps/hippocampus ChildProcessEnvironmentBehavior"
    "capture-source-policy-behavior|swift|test|scripts/swift-package.sh run --package-path adapters/macos/MCICaptureHelper CaptureSourcePolicyBehavior"
    "release-ocr-killswitch|swift|test|scripts/test-release-ocr-killswitch.sh"
    "helper-readiness-behavior|swift|test|scripts/swift-package.sh run --package-path adapters/macos/MCICaptureHelper HelperReadinessBehavior"
    "capture-overlap-corpus|swift|test|scripts/test-capture-overlap-corpus.sh"
    "live-capture-overlap-contract|bash|test|scripts/test-live-capture-overlap-contract.sh"
    "product-source-provenance|bash|test|scripts/test-product-source-provenance.sh"
    "onboarding-route-behavior|swift|test|scripts/swift-package.sh run --package-path apps/onboarding OnboardingRouteBehavior"
    "safari-private-context|bash|test|node --test extensions/safari/__tests__/content.test.cjs"
    "bash-syntax|bash|lint|__bash_syntax_lane"
    "supply-chain-audit-contract|bash|test|python3 -B scripts/test_supply_chain_audit.py"
    "release-contract|bash|lint|scripts/test-release-contract.sh"
    "app-group-contract|bash|test|scripts/test-app-group-contract.sh"
    "toml-license-contract|bash|lint|scripts/test-toml-license-contract.sh"
    "task-2-product-truth|bash|lint|scripts/test-task-2-product-truth.sh"
    "retention-policy-contract|bash|test|scripts/test-retention-policy-contract.sh"
    "release-identity-fixtures|bash|test|scripts/test-release-identity.sh"
    "release-model-fixtures|bash|test|scripts/test-prepare-release-models.sh"
    "release-model-manifest|bash|test|scripts/test-release-model-manifest.sh"
    "coreml-compatibility|bash|test|scripts/test-coreml-compatibility.sh"
    "coreml-compiled-contract|bash|test|python3 scripts/test_coreml_model_contract.py"
    "coreml-converter-contract|bash|test|python3 scripts/test_convert_embedder_contract.py"
    "installer-runtime|bash|test|scripts/test-installer-runtime.sh"
    "sparkle-keygen-fixtures|bash|test|scripts/test-sparkle-keygen.sh"
    "sparkle-keypair-fixtures|bash|test|scripts/test-sparkle-keypair.sh"
    "key-custody-runner|bash|test|scripts/test-agent-key-custody-runner.sh"
    "supervisor-stop-policy|bash|test|scripts/test-supervisor-stop-policy.sh"
    "clean-home-contract|bash|lint|scripts/test-e2e-clean-home-contract.sh"
    "development-app-contract|bash|lint|scripts/test-development-app-contract.sh"
    "development-file-key-contract|bash|test|scripts/test-development-file-key-contract.sh"
    "no-quarantine-bypass|bash|test|scripts/test-no-quarantine-bypass.sh"
    "app-launch-contract|bash|test|scripts/test-verify-app-launches.sh"
    "demo-contract|bash|lint|scripts/test-demo-contract.sh"
    "keyframe-demo-fixture|bash|test|scripts/test-keyframe-demo-fixture.sh"
    "onboarding-product-truth|bash|lint|scripts/test-onboarding-product-truth.sh"
    "product-visual-assets|bash|test|scripts/test-product-visual-assets.sh"
    "screenshot-assets|bash|lint|scripts/test-screenshot-assets.sh"
    "changelog-sanity|bash|lint|__changelog_sanity_lane"
)

# ---- Usage -------------------------------------------------------------------
usage() {
    cat <<'EOF'
check.sh — unified local lint+test gate for MCI (cycle 8.44 runlog pattern §1)

USAGE
    ./scripts/check.sh [SELECTOR ...]
    ./scripts/check.sh --help | -h

SELECTORS
    Families:   rust    swift    bash    all (default)
    Actions:    fmt     lint     test    audit

    No args               -> all lanes.
    One family            -> every lane in that family.
    One action            -> every lane of that action across families.
    Family + action(s)    -> intersection (e.g. `rust lint` = rust-clippy).
    Multiple families     -> union (e.g. `rust swift`).

LANES
    rust-fmt              cargo fmt --check --all
    rust-clippy           cargo clippy --workspace --all-targets
    rust-test             cargo test --workspace
    rust-audit            tracked Cargo.lock audits with JSON evidence and explicit waiver
    swift-fmt             swiftformat --lint (SKIP if not installed)
    swift-package-wrapper compatibility-wrapper behavior and unified-gate contract
    swift-test-helper     swift test in adapters/macos/MCICaptureHelper
    swift-test-recall-ui  swift test in apps/recall-ui
    swift-test-onboarding swift test in apps/onboarding
    swift-test-hippocampus swift test in apps/hippocampus
    recall-state-behavior responsive Recall layout and ephemeral query-state fixture
    recall-refresh-behavior real process-local refresh signal and re-query behavior
    context-handoff-behavior bounded child completion and timeout cleanup
    onboarding-ai-connector bounded first-run AI-client registration and cleanup
    menu-ai-connector      bounded menu-bar AI-client registration and cleanup
    capture-consent-behavior executable capture authority and generation fixture
    child-process-environment prepared file-key authority reaches supervised children
    capture-source-policy-behavior browser pixels stay outside ambient OCR
    release-ocr-killswitch release helper excludes development OCR qualification
    helper-readiness-behavior readiness publication is private, atomic, and add-only
    capture-overlap-corpus deterministic focused/background window fixture builds
    live-capture-overlap-contract live verifier preflight and cleanup remain fail-closed
    product-source-provenance signed qualification source and binary binding contract
    onboarding-route-behavior executable route to the durable app-access editor
    safari-private-context structured browser capture fails closed in private tabs
    bash-syntax           bash -n across repo *.sh files
    supply-chain-audit-contract audit coverage, errors, and empty-selector regression tests
    release-contract      release graph and artifact identity contract
    toml-license-contract pinned TOML dependency license contract
    task-2-product-truth  legal artifact drift and active product-truth contract
    retention-policy-contract Swift picker to Rust purge-worker contract
    release-identity-fixtures release tag, DMG, checksum, and appcast fixtures
    release-model-fixtures immutable model archive integrity fixtures
    release-model-manifest tag-owned model identity fixtures
    coreml-compatibility    packaged model precision and minimum-OS fixtures
    coreml-compiled-contract independently inspect compiled model shape and constants
    coreml-converter-contract canonical converted-model provenance fixture
    installer-runtime       bounded layout process and centralized cleanup fixture
    sparkle-keygen-fixtures bundled Sparkle CLI contract fixture
    sparkle-keypair-fixtures Ed25519 private/public matching fixtures
    key-custody-runner    nonblocking bounded child-process diagnostic fixture
    supervisor-stop-policy bounded two-child shutdown fixture
    clean-home-contract     isolated install-to-uninstall product contract
    development-app-contract debug-only app assembly remains release-safe
    development-file-key-contract signed ad-hoc file-key capability remains release-safe
    no-quarantine-bypass runtime leaves Gatekeeper provenance enforcement to macOS
    app-launch-contract     isolated GUI launch and onboarding process contract
    demo-contract           demo uses disposable state and bundled UI artifacts
    keyframe-demo-fixture   encrypted visual fixture uses the production codec
    onboarding-product-truth onboarding copy preserves local/provider boundaries
    product-visual-assets   app, installer, browser, and screenshot assets share the light identity
    screenshot-assets       screenshots stay light, non-placeholder, and 1280x800
    changelog-sanity      gen-changelog.sh --dry-run smoke

BEHAVIOR
    - Each lane runs isolated; one failure does not abort the others.
    - Optional formatter tools may SKIP; missing audit tooling FAILS.
    - Summary table printed at end with PASS/FAIL/SKIP + duration.
    - Exit 0 only if at least one lane ran and none FAILED (optional SKIP is allowed).

ENVIRONMENT
    CHECK_SH_QUIET=1      suppress per-lane stdout (summary still printed)

EXAMPLES
    ./scripts/check.sh                    # everything
    ./scripts/check.sh rust               # every rust lane
    ./scripts/check.sh swift test         # only swift tests
    ./scripts/check.sh rust fmt lint      # rust-fmt + rust-clippy
    ./scripts/check.sh bash               # bash-syntax only
EOF
}

# ---- Custom lane bodies ------------------------------------------------------
__swift_fmt_lane() {
    if ! command -v swiftformat >/dev/null 2>&1; then
        echo "[skip] swiftformat not installed (brew install swiftformat)"
        return 42  # sentinel: SKIP
    fi
    # Lint mode — no writes, just report drift.
    swiftformat --lint \
        apps/hippocampus/Sources \
        apps/recall-ui/Sources \
        apps/onboarding/Sources \
        adapters/macos/MCICaptureHelper/Sources
}

__changelog_sanity_lane() {
    # Build-hygiene: does gen-changelog.sh --dry-run complete cleanly?
    # Non-blocking style — we only fail on a hard error, not on empty output.
    if [[ ! -x scripts/gen-changelog.sh ]]; then
        echo "[skip] scripts/gen-changelog.sh not present or not executable"
        return 42
    fi
    if ! scripts/gen-changelog.sh --dry-run --since HEAD~20 >/dev/null 2>&1; then
        # Fall back to full history if HEAD~20 does not exist yet (shallow clone).
        scripts/gen-changelog.sh --dry-run >/dev/null
    fi
    echo "gen-changelog.sh --dry-run OK"
}

__bash_syntax_lane() {
    # Collect every *.sh file tracked in the repo (excluding vendor/build outputs)
    # and bash -n each one. Any parse error fails the lane.
    local files
    if command -v git >/dev/null 2>&1 && [[ -d .git ]] || git rev-parse --git-dir >/dev/null 2>&1; then
        files=$(git ls-files '*.sh' 2>/dev/null || true)
    fi
    if [[ -z "${files:-}" ]]; then
        # Fallback: find under scripts/ + top-level *.sh + apps/**/*.sh
        files=$(find scripts apps -type f -name '*.sh' 2>/dev/null || true)
    fi
    if [[ -z "$files" ]]; then
        echo "[skip] no .sh files found"
        return 42
    fi
    local count=0 failed=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        count=$((count + 1))
        if ! bash -n "$f" 2>&1; then
            echo "SYNTAX FAIL: $f"
            failed=$((failed + 1))
        fi
    done <<< "$files"
    echo "checked $count shell file(s), $failed failure(s)"
    [[ $failed -eq 0 ]]
}

# ---- Selector resolution -----------------------------------------------------
# Parse args into two sets: families and actions.
declare -a REQ_FAMILIES=()
declare -a REQ_ACTIONS=()
ALL=0

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        all)      ALL=1 ;;
        rust|swift|bash) REQ_FAMILIES+=("$arg") ;;
        fmt|lint|test|audit) REQ_ACTIONS+=("$arg") ;;
        *)
            echo "check.sh: unknown selector: $arg" >&2
            echo "Try: ./scripts/check.sh --help" >&2
            exit 1
            ;;
    esac
done

# Default: no args -> all
if [[ $# -eq 0 ]] || [[ $ALL -eq 1 ]]; then
    REQ_FAMILIES=(rust swift bash)
    REQ_ACTIONS=(fmt lint test audit)
fi

# If only families given, include all actions. If only actions given, include
# all families. Both means intersection.
if [[ ${#REQ_FAMILIES[@]} -eq 0 ]]; then
    REQ_FAMILIES=(rust swift bash)
fi
if [[ ${#REQ_ACTIONS[@]} -eq 0 ]]; then
    REQ_ACTIONS=(fmt lint test audit)
fi

in_set() {
    local needle="$1"; shift
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

# ---- Run lanes ---------------------------------------------------------------
declare -a RESULT_NAMES=()
declare -a RESULT_STATUSES=()
declare -a RESULT_DURATIONS=()

fail_count=0
pass_count=0
skip_count=0

for row in "${LANES[@]}"; do
    IFS='|' read -r name family action cmd <<< "$row"
    if ! in_set "$family" "${REQ_FAMILIES[@]}"; then continue; fi
    if ! in_set "$action" "${REQ_ACTIONS[@]}"; then continue; fi

    printf "%b==> %s%b %b(%s/%s)%b\n" \
        "$C_BOLD" "$name" "$C_RESET" "$C_DIM" "$family" "$action" "$C_RESET"

    start_ts=$SECONDS
    status="PASS"
    if [[ "$cmd" == __* ]]; then
        # Custom lane body — call the function.
        if [[ "$QUIET" == "1" ]]; then
            output=$("$cmd" 2>&1) && rc=0 || rc=$?
            [[ $rc -eq 42 ]] && status="SKIP"
            [[ $rc -ne 0 && $rc -ne 42 ]] && status="FAIL"
        else
            "$cmd" || rc=$? && rc=${rc:-0}
            [[ $rc -eq 42 ]] && status="SKIP"
            [[ $rc -ne 0 && $rc -ne 42 ]] && status="FAIL"
            unset rc
        fi
    else
        # External shell command.
        if [[ "$QUIET" == "1" ]]; then
            bash -c "$cmd" >/dev/null 2>&1 || status="FAIL"
        else
            bash -c "$cmd" || status="FAIL"
        fi
    fi
    dur=$((SECONDS - start_ts))

    RESULT_NAMES+=("$name")
    RESULT_STATUSES+=("$status")
    RESULT_DURATIONS+=("${dur}s")

    case "$status" in
        PASS) pass_count=$((pass_count + 1));;
        FAIL) fail_count=$((fail_count + 1));;
        SKIP) skip_count=$((skip_count + 1));;
    esac
    echo
done

# ---- Summary -----------------------------------------------------------------
if [[ ${#RESULT_NAMES[@]} -eq 0 ]]; then
    echo '{"check":"check.sh","status":"fail","reason":"no_matching_lanes"}'
    exit 1
fi

echo "${C_BOLD}=================================================${C_RESET}"
echo "${C_BOLD}  check.sh summary${C_RESET}"
echo "${C_BOLD}=================================================${C_RESET}"
printf "  %-24s %-8s %s\n" "LANE" "STATUS" "DURATION"
for i in "${!RESULT_NAMES[@]}"; do
    name="${RESULT_NAMES[$i]}"
    status="${RESULT_STATUSES[$i]}"
    dur="${RESULT_DURATIONS[$i]}"
    case "$status" in
        PASS) mark="${C_GREEN}PASS ✓${C_RESET}" ;;
        FAIL) mark="${C_RED}FAIL ✗${C_RESET}" ;;
        SKIP) mark="${C_YELLOW}SKIP -${C_RESET}" ;;
        *)    mark="$status" ;;
    esac
    printf "  %-24s %b  %s\n" "$name" "$mark" "$dur"
done
echo
printf "  totals: %b%d pass%b · %b%d fail%b · %b%d skip%b\n" \
    "$C_GREEN" "$pass_count" "$C_RESET" \
    "$C_RED"   "$fail_count" "$C_RESET" \
    "$C_YELLOW" "$skip_count" "$C_RESET"

if [[ $fail_count -gt 0 ]]; then
    echo "${C_RED}${C_BOLD}FAIL${C_RESET} — $fail_count lane(s) failed"
    exit 1
fi
echo "${C_GREEN}${C_BOLD}OK${C_RESET} — all invoked lanes passed"
exit 0
