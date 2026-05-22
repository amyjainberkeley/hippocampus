#!/usr/bin/env bash
set -euo pipefail

# tcc-reset.sh — Reset Hippocampus TCC permissions for dev iteration.
#
# Each rebuild changes binary hashes; macOS revokes prior grants.
# This wipes the relevant TCC entries so you can grant fresh.
#
# Usage:
#   scripts/tcc-reset.sh
#
# After running: quit Hippocampus.app, relaunch, grant when prompted.
# Grant Screen Recording for BOTH Hippocampus AND MCICaptureHelper.

echo "Resetting TCC permissions for Hippocampus dev iteration..."

tccutil reset ScreenCapture
tccutil reset Accessibility
tccutil reset SystemPolicyAllFiles

echo "Done. Quit and relaunch Hippocampus.app, then grant fresh."
echo ""
echo "To grant MCICaptureHelper directly:"
echo "  System Settings → Privacy & Security → Screen Recording"
echo "  + → Cmd+Shift+. → ~/Applications/Hippocampus.app/Contents/MacOS/MCICaptureHelper"
