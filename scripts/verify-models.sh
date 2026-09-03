#!/usr/bin/env bash
set -euo pipefail

# verify-models.sh — Validate model bundling in Hippocampus.app.
#
# Reads the BUNDLED manifest (apps/hippocampus/Sources/HippocampusKit/
# Resources/models.json — the file SwiftPM processes into
# Hippocampus_HippocampusKit.bundle and that build-app.sh hoists into
# the .app's Contents/Resources/) and checks:
#   - Bundled models exist in the .app bundle's Resources/Models/
#   - Downloadable models have a real (non-placeholder) sha256
#   - For each downloadable model, the HF tarball's `x-linked-etag`
#     (HF's content-addressed sha) matches the manifest sha256.
#     Requires network; if curl fails (offline build), the check is
#     skipped with a WARN instead of failing.
#
# Reading the bundled copy (not a sibling duplicate) was forced by the
# cycle 8.14 → 8.24 incident: PR #220 updated a non-bundled duplicate
# at apps/hippocampus/Resources/models.json without updating the SwiftPM-
# processed source, so verify-models.sh reported OK while the DMG carried
# the wrong SHA and every Qwen install failed with "Download integrity
# check failed". The duplicate is gone (see docs/research/onboarding-
# wiring-audit-2026-05-30.md §3). Single source of truth from here on.
#
# Usage:
#   scripts/verify-models.sh                              # auto-detect app
#   scripts/verify-models.sh --app path/to/Hippocampus.app
#   scripts/verify-models.sh --manifest path/to/models.json --app path/to/Hippocampus.app
#   scripts/verify-models.sh --allow-missing-bundled --app path/to/Hippocampus.app

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODELS_JSON="$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/Resources/models.json"
APP_PATH=""
ALLOW_MISSING_BUNDLED=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_PATH="$2"; shift 2 ;;
        --manifest) MODELS_JSON="$2"; shift 2 ;;
        --allow-missing-bundled) ALLOW_MISSING_BUNDLED=1; shift ;;
        *) echo "Usage: verify-models.sh [--allow-missing-bundled] [--manifest path/to/models.json] [--app path/to/Hippocampus.app]"; exit 1 ;;
    esac
done

if [[ -z "$APP_PATH" ]]; then
    APP_PATH="$REPO_ROOT/apps/hippocampus/dist/Hippocampus.app"
fi

if [[ ! -f "$MODELS_JSON" ]]; then
    echo "ERROR: models.json not found at $MODELS_JSON"
    exit 1
fi

ERRORS=0

APP_MINIMUM_SYSTEM_VERSION=""
if [[ -f "$APP_PATH/Contents/Info.plist" ]]; then
    APP_MINIMUM_SYSTEM_VERSION=$(python3 - "$APP_PATH/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    value = plistlib.load(handle).get("LSMinimumSystemVersion", "")
print(value)
PY
)
fi

echo "Checking models.json: $MODELS_JSON"
echo "App bundle: $APP_PATH"
echo ""

# Parse models.json with python (available on macOS, no extra deps).
# Use process substitution (not a pipe) so $ERRORS updates inside the
# loop propagate to the parent shell.
while IFS= read -r line; do
    kind="${line%%:*}"
    rest="${line#*:}"

    if [[ "$kind" == "BUNDLED" ]]; then
        model_id="$rest"
        # Map model IDs to their exact runtime paths in the app bundle.
        case "$model_id" in
            arctic-embed-s-fp16)
                compiled_name="ArcticEmbedS_FP16.mlmodelc"
                unavailable_message="Semantic recall stays lexical-only."
                ;;
            arctic-embed-s-int8)
                compiled_name="ArcticEmbedS_INT8.mlmodelc"
                unavailable_message="Semantic recall stays lexical-only."
                ;;
            qwen3-1.7b-fp16)
                compiled_name="qwen3-1.7b-fp16/Qwen3-1.7B-FP16.mlmodelc"
                unavailable_message="Generated daily briefs stay disabled."
                ;;
            *)
                compiled_name="${model_id}.mlmodelc"
                unavailable_message="The model-backed feature stays disabled."
                ;;
        esac

        model_path="$APP_PATH/Contents/Resources/Models/$compiled_name"
        if [[ -d "$model_path" ]]; then
            echo "  OK: bundled model '$model_id' found at $model_path"
            metadata_path="$model_path/metadata.json"
            compatibility_path="$model_path/hippocampus-model.json"
            model_minimum_system_version=""
            storage_precision=""
            compatibility_model_id=""
            if [[ -f "$compatibility_path" ]]; then
                model_minimum_system_version=$(python3 - "$compatibility_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    metadata = json.load(handle)
print(metadata.get("minimumSystemVersion", ""))
PY
)
                storage_precision=$(python3 - "$compatibility_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    metadata = json.load(handle)
print(metadata.get("precision", ""))
PY
)
                compatibility_model_id=$(python3 - "$compatibility_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    metadata = json.load(handle)
print(metadata.get("modelID", ""))
PY
)
            elif [[ -f "$metadata_path" ]]; then
                model_minimum_system_version=$(python3 - "$metadata_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    metadata = json.load(handle)
record = metadata[0] if isinstance(metadata, list) and metadata else metadata
print(record.get("availability", {}).get("macOS", ""))
PY
)
                storage_precision=$(python3 - "$metadata_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    metadata = json.load(handle)
record = metadata[0] if isinstance(metadata, list) and metadata else metadata
print(record.get("storagePrecision", ""))
PY
)
            else
                echo "  ERROR: bundled model '$model_id' has no compatibility metadata"
                echo "         Expected $compatibility_path or $metadata_path"
                ERRORS=$((ERRORS + 1))
            fi
            if [[ -n "$compatibility_model_id" && "$compatibility_model_id" != "$model_id" ]]; then
                echo "  ERROR: bundled model '$model_id' compatibility metadata identifies '$compatibility_model_id'"
                ERRORS=$((ERRORS + 1))
            fi
            if [[ -n "$APP_MINIMUM_SYSTEM_VERSION" && -n "$model_minimum_system_version" ]] && ! python3 - "$APP_MINIMUM_SYSTEM_VERSION" "$model_minimum_system_version" <<'PY'
import sys

def version(value):
    return tuple(int(part) for part in value.split("."))

app = version(sys.argv[1])
model = version(sys.argv[2])
width = max(len(app), len(model))
raise SystemExit(0 if app + (0,) * (width - len(app)) >= model + (0,) * (width - len(model)) else 1)
PY
            then
                echo "  ERROR: bundled model '$model_id' requires macOS $model_minimum_system_version but the app supports macOS $APP_MINIMUM_SYSTEM_VERSION"
                ERRORS=$((ERRORS + 1))
            fi
            if [[ -n "$storage_precision" ]]; then
                model_identity="$model_id/$compiled_name"
                case "$model_identity" in
                    *fp16*|*FP16*)
                        case "$storage_precision" in
                            *float16*|*Float16*|*FP16*) ;;
                            *)
                                echo "  ERROR: bundled model '$model_id' claims FP16 but compatibility metadata says $storage_precision"
                                ERRORS=$((ERRORS + 1))
                                ;;
                        esac
                        ;;
                    *int8*|*INT8*)
                        case "$storage_precision" in
                            *Int8*|*INT8*) ;;
                            *)
                                echo "  ERROR: bundled model '$model_id' claims INT8 but compiled storage precision is $storage_precision"
                                ERRORS=$((ERRORS + 1))
                                ;;
                        esac
                        ;;
                esac
            fi
        elif [[ "$ALLOW_MISSING_BUNDLED" -eq 1 ]]; then
            echo "  WARN: bundled model '$model_id' NOT found at $model_path"
            echo "        $unavailable_message"
            echo "        Missing model explicitly allowed for this development-lite check."
        else
            echo "  ERROR: required bundled model '$model_id' NOT found at $model_path"
            echo "         $unavailable_message"
            ERRORS=$((ERRORS + 1))
        fi
    elif [[ "$kind" == "DOWNLOAD" ]]; then
        # Format: DOWNLOAD:<id>:<sha>:<url>
        model_id=$(printf '%s\n' "$rest" | cut -d: -f1)
        sha=$(printf '%s\n' "$rest" | cut -d: -f2)
        url=$(printf '%s\n' "$rest" | cut -d: -f3-)
        if [[ "$sha" == "PLACEHOLDER_UNTIL_MODEL_IS_CONVERTED" || -z "$sha" ]]; then
            echo "  WARN: downloadable model '$model_id' has placeholder sha256"
            echo "        Run convert_brief_model.py and update models.json."
            ERRORS=$((ERRORS + 1))
        else
            echo "  OK: downloadable model '$model_id' has sha256: ${sha:0:16}..."
        fi

        # HF drift gate. Fetches the redirect target's `x-linked-etag`
        # (HF's content-addressed sha) and compares to the manifest
        # sha. Mismatch = the bundled DMG will fail SHA verification at
        # install time on every user machine (the cycle 8.14 incident).
        # Network failure (offline build, CI without egress) is a WARN,
        # not a hard fail.
        if [[ -n "$url" && "$url" == https://huggingface.co/* ]]; then
            etag=$(curl -sI "$url" 2>/dev/null | awk '/^x-linked-etag:/ {print $2}' | tr -d '"\r\n' || true)
            if [[ -z "$etag" ]]; then
                echo "  WARN: could not HEAD '$url' (offline build?) — skipping HF drift check"
            elif [[ "$etag" == "$sha" ]]; then
                echo "  OK: HF artifact for '$model_id' matches manifest sha256"
            else
                echo "  ERROR: HF artifact for '$model_id' has sha $etag"
                echo "         but manifest says $sha"
                echo "         → users will see 'Download integrity check failed'."
                echo "         Update apps/hippocampus/Sources/HippocampusKit/Resources/models.json."
                ERRORS=$((ERRORS + 1))
            fi
        fi
    fi
done < <(python3 -c "
import json, sys

with open('$MODELS_JSON') as f:
    manifest = json.load(f)

for m in manifest.get('models', []):
    mid = m.get('modelID', '???')
    bundled = m.get('bundled', False)
    sha = m.get('sha256', '')
    url = m.get('downloadURL', '')

    if bundled:
        print(f'BUNDLED:{mid}')
    else:
        print(f'DOWNLOAD:{mid}:{sha}:{url}')
")

if [[ "$ERRORS" -gt 0 ]]; then
    echo ""
    echo "RESULT: $ERRORS check(s) failed."
    exit 1
fi

echo ""
echo "RESULT: All checks passed."
