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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODELS_JSON="$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/Resources/models.json"
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

# Parse models.json with python (available on macOS, no extra deps).
# Use process substitution (not a pipe) so $ERRORS updates inside the
# loop propagate to the parent shell.
while IFS= read -r line; do
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
