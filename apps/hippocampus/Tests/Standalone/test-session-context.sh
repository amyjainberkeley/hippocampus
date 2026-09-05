#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT"
cat apps/hippocampus/Sources/HippocampusKit/KeyCustodyCommandRunner.swift \
    apps/hippocampus/Sources/HippocampusKit/SessionContextHook.swift \
    apps/hippocampus/Sources/HippocampusKit/SessionContextInstaller.swift \
    apps/hippocampus/Tests/Standalone/SessionContextBehavior.swift \
    | scripts/swift-package.sh -swift-version 6 -package-name Hippocampus -
