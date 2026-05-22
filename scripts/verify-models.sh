#!/usr/bin/env bash
set -euo pipefail

# verify-models.sh — Validate model bundling in Hippocampus.app.
#
# Reads apps/hippocampus/Resources/models.json and checks:
#   - Bundled models exist in the .app bundle's Resources/Models/
#   - Downloadable models have a real (non-placeholder) sha256
#
# Usage:
#   scripts/verify-models.sh                              # auto-detect app
#   scripts/verify-models.sh --app path/to/Hippocampus.app

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODELS_JSON="$REPO_ROOT/apps/hippocampus/Resources/models.json"
APP_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_PATH="$2"; shift 2 ;;
        *) echo "Usage: verify-models.sh [--app path/to/Hippocampus.app]"; exit 1 ;;
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

echo "Checking models.json: $MODELS_JSON"
echo "App bundle: $APP_PATH"
echo ""

# Parse models.json with python (available on macOS, no extra deps)
python3 -c "
import json, sys

with open('$MODELS_JSON') as f:
    manifest = json.load(f)

for m in manifest.get('models', []):
    mid = m.get('modelID', '???')
    bundled = m.get('bundled', False)
    sha = m.get('sha256', '')

    if bundled:
        print(f'BUNDLED:{mid}')
    else:
        print(f'DOWNLOAD:{mid}:{sha}')
" | while IFS= read -r line; do
    kind="${line%%:*}"
    rest="${line#*:}"

    if [[ "$kind" == "BUNDLED" ]]; then
        model_id="$rest"
        # Map model IDs to expected .mlmodelc directory names
        case "$model_id" in
            arctic-embed-s-int8) compiled_name="ArcticEmbedS_INT8.mlmodelc" ;;
            *) compiled_name="${model_id}.mlmodelc" ;;
        esac

        model_path="$APP_PATH/Contents/Resources/Models/$compiled_name"
        if [[ -d "$model_path" ]]; then
            echo "  OK: bundled model '$model_id' found at $model_path"
        else
            echo "  WARN: bundled model '$model_id' NOT found at $model_path"
            echo "        Semantic search will use zero-vector stub fallback."
            # Not a hard error — build works without bundled models
        fi
    elif [[ "$kind" == "DOWNLOAD" ]]; then
        model_id="${rest%%:*}"
        sha="${rest#*:}"
        if [[ "$sha" == "PLACEHOLDER_UNTIL_MODEL_IS_CONVERTED" || -z "$sha" ]]; then
            echo "  WARN: downloadable model '$model_id' has placeholder sha256"
            echo "        Run convert_brief_model.py and update models.json."
            ERRORS=$((ERRORS + 1))
        else
            echo "  OK: downloadable model '$model_id' has sha256: ${sha:0:16}..."
        fi
    fi
done

# Propagate error count from subshell via a second pass
DOWNLOAD_ERRORS=$(python3 -c "
import json
with open('$MODELS_JSON') as f:
    manifest = json.load(f)
errors = 0
for m in manifest.get('models', []):
    if not m.get('bundled', False):
        sha = m.get('sha256', '')
        if sha == 'PLACEHOLDER_UNTIL_MODEL_IS_CONVERTED' or not sha:
            errors += 1
print(errors)
")

if [[ "$DOWNLOAD_ERRORS" -gt 0 ]]; then
    echo ""
    echo "RESULT: $DOWNLOAD_ERRORS downloadable model(s) have placeholder sha256."
    exit 1
fi

echo ""
echo "RESULT: All checks passed."
