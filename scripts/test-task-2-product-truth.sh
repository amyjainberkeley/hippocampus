#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GENERATOR="$REPO_ROOT/assets/installer/generate-eula.py"
SOURCE="$REPO_ROOT/docs/legal/terms-of-service.md"
EULA="$REPO_ROOT/assets/installer/EULA.rtf"
INSTALLER="$REPO_ROOT/scripts/build-installer.sh"
PREFERENCES_STORE="$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/PreferencesStore.swift"
PREFERENCES_WINDOW="$REPO_ROOT/apps/hippocampus/Sources/Hippocampus/PreferencesWindow.swift"
RUNTIME_CONFIG="$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/RuntimeConfig.swift"
PROCESS_SUPERVISOR="$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/ProcessSupervisor.swift"
RETENTION_WORKER="$REPO_ROOT/apps/agent/src/retention_worker.rs"
AGENT_MAIN="$REPO_ROOT/apps/agent/src/bin/mci_agent.rs"
STATUS_MENU="$REPO_ROOT/apps/hippocampus/Sources/Hippocampus/StatusMenuView.swift"
CAPTURE_HEALTH="$REPO_ROOT/apps/hippocampus/Sources/Hippocampus/CaptureHealthView.swift"
APP="$REPO_ROOT/apps/hippocampus/Sources/Hippocampus/HippocampusApp.swift"
README="$REPO_ROOT/README.md"
STATUS="$REPO_ROOT/docs/STATUS.md"
ONBOARDING_RETENTION_STORE="$REPO_ROOT/apps/onboarding/Sources/OnboardingKit/DiskRetentionStore.swift"
ONBOARDING_RETENTION_MODEL="$REPO_ROOT/apps/onboarding/Sources/OnboardingKit/RetentionViewModel.swift"
ONBOARDING_FLOW="$REPO_ROOT/apps/onboarding/Sources/Onboarding/OnboardingFlowView.swift"
ONBOARDING_APP="$REPO_ROOT/apps/onboarding/Sources/Onboarding/OnboardingApp.swift"
ONBOARDING_STEP="$REPO_ROOT/apps/onboarding/Sources/OnboardingKit/OnboardingStep.swift"

python3 "$GENERATOR" --check

rg -Fq 'Hippocampus itself has no cloud service.' "$README"
rg -Fq 'a connected AI client sends only the context it requests to its selected provider' \
    "$README"
if rg -Fq 'nothing is sent anywhere' "$README"; then
    echo "FAIL: README hides the connected AI provider boundary" >&2
    exit 1
fi

for stale_release_claim in \
    'This machine has Command Line Tools rather than full Xcode' \
    'The build is not signed or notarized under my own Apple Developer ID yet' \
    'It is not notarized under my own Apple Developer ID yet'; do
    if rg -Fq "$stale_release_claim" "$README" "$STATUS"; then
        echo "FAIL: stale owner release prerequisite remains: $stale_release_claim" >&2
        exit 1
    fi
done
rg -Uq 'Full Xcode 26\.6 is installed and selected' "$STATUS"
rg -Uq 'The Developer ID Application[[:space:]]+identity and its private key are installed' "$STATUS"
rg -Uq '`notarytool-profile` authenticates[[:space:]]+successfully' "$STATUS"
rg -Uq 'Sparkle private/public key pair matches' "$STATUS"

rg -Fq 'Deleted memories are removed as database rows and local storage is compacted.' \
    "$REPO_ROOT/apps/onboarding/Sources/Onboarding/Slides/RetentionSlide.swift"
rg -Fq 'python3 "$GENERATE_EULA" --check' "$INSTALLER"
rg -Fq 'cp "$EULA_RTF" "$DMG_STAGING/Legal/License.rtf"' "$INSTALLER"
if rg -q 'hdiutil (unflatten|flatten)|Rez -append' "$INSTALLER"; then
    echo "FAIL: installer still uses the removed legacy DMG SLA resource flow" >&2
    exit 1
fi
rg -Fq '.appendingPathComponent("MCI")' "$PREFERENCES_STORE"
rg -Fq '.appendingPathComponent("retention.json")' "$PREFERENCES_STORE"
rg -Fq 'replaceItemAt(' "$PREFERENCES_STORE"
rg -Fq '[.posixPermissions: 0o600]' "$PREFERENCES_STORE"
rg -Fq 'db_path.with_file_name("retention.json")' "$AGENT_MAIN"
rg -Fq 'setRetentionPolicy(' "$PREFERENCES_WINDOW"
rg -Fq '"thirtyDays" => Ok(RetentionConfig::Days(30))' "$RETENTION_WORKER"
rg -Fq '"sevenDays" => Ok(RetentionConfig::Days(7))' "$RETENTION_WORKER"
rg -Fq 'Some(days) if (1..=365).contains(&days)' "$RETENTION_WORKER"
rg -Fq 'try writer.write(data, to: fileURL)' "$ONBOARDING_RETENTION_STORE"
rg -Fq 'cached = (policy, validatedDays, false)' "$ONBOARDING_RETENTION_STORE"
rg -Fq 'public func saveThen(' "$ONBOARDING_RETENTION_MODEL"
rg -Fq 'await retentionVM.saveThen { flowVM.advance() }' "$ONBOARDING_FLOW"
rg -Fq 'parsed[key] = value' "$RUNTIME_CONFIG"
rg -Fq 'parsed.convert(to: .toml)' "$RUNTIME_CONFIG"
rg -Fq 'captureEnabled: supervisor.captureEnabled' "$STATUS_MENU" "$APP"
rg -Fq 'environment["MCI_ONBOARDING_STEP"] = initialStep' "$PROCESS_SUPERVISOR"
rg -Fq 'OnboardingStep.init(launchRoute:)' "$ONBOARDING_APP"
rg -Fq 'case "allowlist", "app-access": self = .allowlist' "$ONBOARDING_STEP"
if rg -q 'deepHookPlugins|defaultDeepHookPlugins|deepHookPluginOrder' \
    "$PREFERENCES_STORE" "$PREFERENCES_WINDOW"; then
    echo "FAIL: disconnected UserDefaults deep-hook control returned" >&2
    exit 1
fi
rg -Fq 'RecordingControl.derive(' "$STATUS_MENU"
rg -Fq 'CaptureHealthView(supervisor: supervisor)' "$STATUS_MENU"
rg -Fq 'let status = supervisor.menuBarStatus' "$CAPTURE_HEALTH"
rg -Fq 'Text(status.displayText)' "$CAPTURE_HEALTH"
if rg -Fq 'defaults.set(retentionPolicy.rawValue' "$PREFERENCES_STORE"; then
    echo "FAIL: UserDefaults remains a competing retention authority" >&2
    exit 1
fi
if rg -q 'assignmentKey\(|isTableHeader\(|equalsAfterKey\(' "$RUNTIME_CONFIG"; then
    echo "FAIL: RuntimeConfig still mutates TOML through a physical-line scanner" >&2
    exit 1
fi

for prohibited in \
    'crypto[[:space:]-]*shred' \
    'zero[[:space:]-]*knowledge' \
    'Secure[[:space:]]+Enclave' \
    'Neural[[:space:]]+Engine' \
    'sqlite[[:space:]-]*vec' \
    'no[[:space:]]+third[[:space:]]+party[[:space:]]+can[[:space:]]+decrypt'; do
    if rg -i -q -- "$prohibited" \
        "$SOURCE" "$EULA" \
        "$REPO_ROOT/apps/onboarding/Sources/Onboarding/Slides/RetentionSlide.swift" \
        "$REPO_ROOT/apps/agent/src/bin/mci_seed_brain.rs" \
        "$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/MciBootGuards.swift" \
        "$REPO_ROOT/docs/assets/data-flow-diagram.svg"; then
        echo "FAIL: prohibited unshipped guarantee remains: $prohibited" >&2
        exit 1
    fi
done

FIXTURE="$(mktemp -d -t hippocampus-legal-contract)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/assets/installer" "$FIXTURE/docs/legal"
cp "$GENERATOR" "$EULA" "$FIXTURE/assets/installer/"
cp "$SOURCE" "$FIXTURE/docs/legal/"

printf '\nDRIFT\n' >>"$FIXTURE/assets/installer/EULA.rtf"
if python3 "$FIXTURE/assets/installer/generate-eula.py" --check >/dev/null 2>&1; then
    echo "FAIL: legal artifact drift was accepted" >&2
    exit 1
fi

cp "$EULA" "$FIXTURE/assets/installer/EULA.rtf"
printf '\nThe product guarantees zero-knowledge storage.\n' >>"$FIXTURE/docs/legal/terms-of-service.md"
if python3 "$FIXTURE/assets/installer/generate-eula.py" --check >/dev/null 2>&1; then
    echo "FAIL: prohibited legal guarantee was accepted" >&2
    exit 1
fi

echo "PASS: Task 2 product truth and legal drift contract"
