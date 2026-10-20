#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# no-egress.sh — static egress audit for the shipping code.
#
# What a careful Hacker News reader asks: "You say it stays on my Mac.
# Show me every line that can open a network connection, and prove none
# of them is a surprise." This script answers that from the source.
#
# It greps every shipping crate and Swift/Python/JS source file for the
# APIs that actually open a socket or make a request, then classifies
# each file that has one as:
#
#   (a) UPDATE     — the Sparkle update check to the GitHub releases host
#   (b) LOOPBACK   — a connection that cannot leave this Mac: the local
#                    model server (Ollama / LM Studio) or a loopback-only
#                    MCP server the user opted into
#       GUARD      — code that BLOCKS the network (not a connection)
#       IPC        — a Unix-domain socket (local IPC, never a network hop)
#       BUILD-ONLY — a build/release tool, not in the shipped binary
#       COMMENT    — the symbol appears only in a comment, not a call
#   (c) UNEXPECTED — anything else. Any (c) fails the audit (exit 1).
#
# Why symbols, not URL strings: a string like "https://example.com" stored
# in the brain or shown in the UI is DATA — it cannot make the app connect.
# Only a call into a networking API can. So this audit keys on those APIs.
# (Runtime confirmation that nothing actually dials out is a separate,
# human-run step: see docs/launch/network-check.md.)
#
# The allowlist below is the audit's ledger: each entry names a file, its
# category, and why it is safe, with a file:line a reviewer can open. A new
# shipping file that opens a socket and is NOT on the ledger fails the run —
# that is the point. Tighten the ledger; never loosen it to pass.
#
# Read-only. Builds nothing, connects to nothing, prints no screen content.
#
# Usage:  scripts/launch/no-egress.sh
# Env:    HIPPO_UPDATE_HOST  expected Sparkle feed host (default github.com)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

UPDATE_HOST="${HIPPO_UPDATE_HOST:-github.com}"

# Shipping source roots (the binaries in Hippocampus.app + the browser
# extension). Eval/bench/doc trees are not shipped and are not audited.
ROOTS=(
  apps/agent
  apps/hippocampus
  apps/hippocampus-native-host
  apps/mind
  apps/onboarding
  apps/recall-ui
  core
  adapters/macos
  tools/ocr
  extensions
)

# Build outputs under those roots are not shipping source, and they hold
# third-party code that does open sockets: SwiftPM's checkouts (Sparkle) in
# .build/, Cargo's target/, the OCR worker's .venv/, PyInstaller's build/ and
# dist/. Run in a built checkout, the audit skips them, as it would on a
# clean export. A tracked file under one of these names is never skipped
# silently: the invariant below fails instead.
BUILD_OUTPUT_DIRS=(.build target dist build .venv venv __pycache__ node_modules DerivedData .swiftpm)
EXCLUDES=()
for dir in "${BUILD_OUTPUT_DIRS[@]}"; do
  EXCLUDES+=("--exclude-dir=$dir")
done

# Connection-capable symbols: the APIs that open a socket / make a request
# / fetch an update. NOT bare URL strings (those are data; see header).
SYMBOLS='URLSession|URLRequest|\.dataTask|\.downloadTask|\.uploadTask|NWConnection|NWListener|CFSocket|CFStreamCreate|getaddrinfo|SPUUpdater|SPUStandardUpdater|import Sparkle|SUFeedURL|reqwest|\bureq\b|isahc|surf::|hyper::|hyper_util|HttpConnector|TcpStream|TcpListener|UdpSocket|tokio::net::Tcp|lookup_host|std::net::|urllib|import requests|httpx|aiohttp|http\.client|urlopen|socket\.socket'

# Drop test files (not shipped): dirs named Tests/tests/__tests__, and
# filenames test_*.* / *_test.* / *Tests.swift / *Test.swift.
is_test_path() {
  case "$1" in
    */Tests/*|*/tests/*|*/__tests__/*) return 0 ;;
    */test_*.py|*_test.py|*_test.rs|*_test.js) return 0 ;;
    *Tests.swift|*Test.swift|*.test.js|*.test.cjs) return 0 ;;
    *) return 1 ;;
  esac
}

# ── The allowlist ledger ───────────────────────────────────────────────
# path|category|reason (reason carries a file:line to open).
ALLOWLIST=(
  "apps/hippocampus/Sources/HippocampusKit/Updater.swift|UPDATE|Sparkle polls the signed appcast on the GitHub releases host; feed URL in apps/hippocampus/Resources/Info.plist:59"
  "apps/mind/Sources/MindKit/LocalServerEngine.swift|LOOPBACK|local model server; LocalServerEngine.local() (LocalServerEngine.swift:154) rejects every host but 127.0.0.1/localhost/::1, refuses redirects, uses an ephemeral no-cookie session"
  "core/mcp-client/src/transport/http_sse.rs|LOOPBACK|opt-in MCP server; dials only through LoopbackOnlyConnector and refuses HTTPS (http_sse.rs:34); every URL re-validated at connect time"
  "core/mcp-client/src/transport/loopback.rs|LOOPBACK|the loopback validator itself: LoopbackHost::parse + resolve_now (loopback.rs) reject any non-127.0.0.0/8, non-::1 address at registration AND connect time"
  "apps/onboarding/Sources/OnboardingKit/BundleDisplayNameResolver.swift|COMMENT|the token URLSession appears only in a doc comment about splitting camelCase names (BundleDisplayNameResolver.swift:119); no network call"
  "tools/ocr/worker.py|GUARD|shipping OCR worker; stdin/stdout only. Turns ONNX Runtime's telemetry off before it loads (worker.py:15), installs sys.addaudithook(deny_network) blocking socket.connect/bind (worker.py:590) and DownloadFile.run=deny_download blocking model fetches (worker.py:81); the helper starts it under sandbox-exec with the network denied (OCRWorkerSandbox.swift:60)"
  "tools/ocr/prepare.py|BUILD-ONLY|model fetcher run at release-prep only; the frozen runtime worker is built from worker.py, which blocks downloads (bundle.py refuses a worker carrying extra libs)"
)

allow_lookup() { # $1=path -> prints "category|reason" or empty
  local p="$1" entry
  for entry in "${ALLOWLIST[@]}"; do
    if [[ "${entry%%|*}" == "$p" ]]; then
      printf '%s' "${entry#*|}"
      return 0
    fi
  done
  return 1
}

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
[[ -t 1 ]] || { RED=; GRN=; YEL=; DIM=; RST=; }

fail=0
echo "Hippocampus egress audit — $(git rev-parse --short HEAD 2>/dev/null || echo '?') — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Repo: $REPO_ROOT"
echo

# ── 1. Classify every shipping file that has a connection-capable symbol ─
echo "== Outbound-capable sites, classified =="
# Collect hit files (bash 3.2-compatible: no mapfile).
HIT_FILES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && HIT_FILES+=("$line")
done < <(
  grep -rlnE "$SYMBOLS" "${ROOTS[@]}" "${EXCLUDES[@]}" \
    --include='*.swift' --include='*.rs' --include='*.py' --include='*.js' 2>/dev/null \
  | sort -u
)

printf '%-62s  %-10s  %s\n' "FILE" "CATEGORY" "WHY"
for f in ${HIT_FILES[@]+"${HIT_FILES[@]}"}; do
  is_test_path "$f" && continue
  if meta="$(allow_lookup "$f")"; then
    cat="${meta%%|*}"; why="${meta#*|}"
    color="$GRN"; [[ "$cat" == "UPDATE" ]] && color="$YEL"
    printf '%-62s  %b%-10s%b  %s%s%s\n' "$f" "$color" "$cat" "$RST" "$DIM" "$why" "$RST"
  else
    cat="UNEXPECTED"
    printf '%-62s  %b%-10s%b  %s\n' "$f" "$RED" "$cat" "$RST" "not on the egress ledger — review before launch"
    fail=1
  fi
done
echo

# ── 2. Hard invariants (teeth) ─────────────────────────────────────────
echo "== Invariants =="

check() { # $1=label ; $2=0/1 pass ; $3=detail
  if [[ "$2" -eq 0 ]]; then
    printf '  %bPASS%b %s %s%s%s\n' "$GRN" "$RST" "$1" "$DIM" "$3" "$RST"
  else
    printf '  %bFAIL%b %s %s\n' "$RED" "$RST" "$1" "$3"
    fail=1
  fi
}

ship_rs() { grep -rnE "$1" "${ROOTS[@]}" "${EXCLUDES[@]}" --include='*.rs' 2>/dev/null | grep -vE '/(tests|Tests)/' | grep -vE '_test\.rs:'; }
ship_swift() { grep -rnE "$1" "${ROOTS[@]}" "${EXCLUDES[@]}" --include='*.swift' 2>/dev/null | grep -vE 'Tests?\.swift:'; }

# (o) The build-output folders skipped above hold no tracked source. Only
#     checked in a git checkout; a clean export has no build outputs.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  build_dirs_re="$(IFS='|'; printf '%s' "${BUILD_OUTPUT_DIRS[*]}" | sed 's/\./\\./g')"
  hidden="$(git ls-files -- "${ROOTS[@]}" 2>/dev/null | grep -E "(^|/)($build_dirs_re)/" | head -3)"
  if [[ -z "$hidden" ]]; then
    check "no tracked source under a skipped build-output folder (${BUILD_OUTPUT_DIRS[*]})" 0 ""
  else
    check "no tracked source under a skipped build-output folder" 1 "$(echo "$hidden" | tr '\n' ' ')"
  fi
fi

# (i) No general-purpose HTTP client crate in the shipped Rust.
bad="$(ship_rs 'reqwest|\bureq\b|isahc|surf::|curl::' | grep -vE '#\[cfg\(test' )"
if [[ -z "$bad" ]]; then check "no reqwest/ureq/isahc/surf/curl HTTP client in shipping Rust" 0 "(hyper is allowed, loopback-only, see below)"; else check "no general HTTP client crate" 1 "$(echo "$bad" | head -3)"; fi

# (ii) hyper / HttpConnector / TcpStream in Rust live ONLY in the loopback transport.
off="$(ship_rs 'hyper::|hyper_util|HttpConnector|TcpStream|UdpSocket|TcpListener' | grep -vE '^core/mcp-client/src/transport/' )"
if [[ -z "$off" ]]; then check "hyper/TCP in Rust confined to core/mcp-client/src/transport" 0 ""; else check "hyper/TCP confined to loopback transport" 1 "$(echo "$off" | head -3)"; fi

# (iii) Actual URLSession/dataTask CALLS in Swift live ONLY in LocalServerEngine.
off="$(ship_swift 'URLSession\(|\.dataTask\(|\.downloadTask\(|\.uploadTask\(' | grep -vE '^apps/mind/Sources/MindKit/LocalServerEngine.swift:' )"
if [[ -z "$off" ]]; then check "URLSession calls in Swift confined to LocalServerEngine (loopback)" 0 ""; else check "URLSession calls confined to LocalServerEngine" 1 "$(echo "$off" | head -3)"; fi

# (iv) No TCP/UDP listener bound anywhere in shipping Rust (only AF_UNIX).
lst="$(ship_rs 'TcpListener|UdpSocket' | grep -vE '#\[cfg\(test')"
if [[ -z "$lst" ]]; then check "no TCP/UDP listener in shipping Rust (IPC is AF_UNIX only)" 0 ""; else check "no TCP/UDP listener" 1 "$(echo "$lst" | head -3)"; fi

# (v) Sparkle feed URL: https, on the expected update host.
PLIST="apps/hippocampus/Resources/Info.plist"
feed="$(grep -A1 '<key>SUFeedURL</key>' "$PLIST" 2>/dev/null | grep '<string>' | sed -E 's:.*<string>(.*)</string>.*:\1:' | head -1)"
if [[ "$feed" == https://* && "$feed" == *"$UPDATE_HOST"/* ]]; then
  check "Sparkle SUFeedURL is https on $UPDATE_HOST" 0 "$feed"
else
  check "Sparkle SUFeedURL is https on $UPDATE_HOST" 1 "got: ${feed:-<none>}"
fi

echo
if [[ "$fail" -eq 0 ]]; then
  printf '%bEGRESS AUDIT PASS%b — every outbound-capable site is (a) the update check or (b) loopback-only; no unexpected network code.\n' "$GRN" "$RST"
  exit 0
else
  printf '%bEGRESS AUDIT FAIL%b — see UNEXPECTED / FAIL rows above.\n' "$RED" "$RST"
  exit 1
fi
