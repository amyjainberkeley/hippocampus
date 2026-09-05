#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT"
cat apps/hippocampus/Sources/HippocampusKit/SupervisorState.swift \
    apps/hippocampus/Sources/HippocampusKit/CaptureStatusReceipt.swift \
    apps/hippocampus/Sources/HippocampusKit/HealthSnapshot.swift \
    apps/hippocampus/Sources/HippocampusKit/MenuBarStatus.swift \
    apps/hippocampus/Tests/Standalone/MenuBarStaticBehavior.swift \
    | scripts/swift-package.sh -swift-version 6 - \
        apps/hippocampus/Sources/HippocampusKit/MenuBarStatus.swift
