#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec xcrun swift "$SCRIPT_DIR/verify_sparkle_signature.swift" "$@"
