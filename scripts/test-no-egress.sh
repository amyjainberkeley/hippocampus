#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# scripts/launch/no-egress.sh judges the shipping source, wherever it runs.
#
# Readers are told to run it after building. It used to fail in any built
# checkout, because it read SwiftPM's checkouts (Sparkle) under .build/ and
# the OCR worker's .venv/, and pass only on a clean export (reports/e2e,
# finding 9). This test copies the tracked shipping source into a throwaway
# folder and runs the audit there:
#
#   1. as a clean export: it passes;
#   2. with build outputs full of network code (.build, target, .venv, dist,
#      build, node_modules): it still passes, and names none of them;
#   3. with one real, unexpected network call in shipping source: it fails
#      and names that file;
#   4. in a git checkout, with network code tracked under a folder named like
#      a build output: it fails, so the skip can never hide source.
#
# Read-only for the repository; everything happens in the throwaway folder.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/no-egress-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

ROOTS=(apps/agent apps/hippocampus apps/hippocampus-native-host apps/mind apps/onboarding
    apps/recall-ui core adapters/macos tools/ocr extensions)

# The tracked shipping source as it is in the working tree, plus the audit
# itself and the plist it reads.
TREE="$WORK/tree"
mkdir -p "$TREE"
(
    cd "$REPO_ROOT"
    git ls-files -z -- "${ROOTS[@]}" scripts/launch/no-egress.sh apps/hippocampus/Resources/Info.plist |
        while IFS= read -r -d '' path; do
            [[ -f "$path" ]] && printf '%s\0' "$path"
        done | /usr/bin/xargs -0 /usr/bin/tar -cf - |
        /usr/bin/tar -xf - -C "$TREE"
)
[[ -f "$TREE/scripts/launch/no-egress.sh" ]] || fail "the audit was not copied"

audit() { # $1 = log; runs outside any git checkout unless the tree has one
    (cd "$TREE" && env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$WORK" LANG=en_US.UTF-8 \
        /bin/bash scripts/launch/no-egress.sh) > "$1" 2>&1
}

put() { # $1 = path in the tree, $2 = contents
    mkdir -p "$(dirname "$TREE/$1")"
    printf '%s\n' "$2" > "$TREE/$1"
}

# 1. A clean export.
audit "$WORK/clean.log" || fail "a clean export fails: $(grep -E 'UNEXPECTED|FAIL' "$WORK/clean.log" | head -3)"
grep -q 'EGRESS AUDIT PASS' "$WORK/clean.log" || fail "a clean export does not say PASS"

# 2. The same tree, built: third-party network code in every build output.
BUILT=(
    "apps/hippocampus/.build/checkouts/Sparkle/Sources/SUDownloader.swift|let task = URLSession(configuration: .default).downloadTask(with: request)"
    "apps/recall-ui/.build/checkouts/swift-nio/Sources/Socket.swift|let connection = NWConnection(host: host, port: port, using: .tcp)"
    "tools/ocr/.venv/lib/python3.12/site-packages/requests/api.py|import requests; from urllib.request import urlopen"
    "tools/ocr/dist/hippocampus-ocr/_internal/http/client.py|import http.client; socket.socket()"
    "tools/ocr/build/worker/localpycs/net.py|import httpx"
    "apps/agent/target/debug/build/out/client.rs|let body = reqwest::blocking::get(url); let s = TcpStream::connect(addr);"
    "extensions/chromium/node_modules/fetcher/index.js|const s = new URLSession(); socket.socket()"
)
for entry in "${BUILT[@]}"; do
    put "${entry%%|*}" "${entry#*|}"
done
audit "$WORK/built.log" || fail "a built tree fails: $(grep -E 'UNEXPECTED|FAIL' "$WORK/built.log" | head -3)"
grep -q 'EGRESS AUDIT PASS' "$WORK/built.log" || fail "a built tree does not say PASS"
for entry in "${BUILT[@]}"; do
    path="${entry%%|*}"
    ! grep -Fq "$path" "$WORK/built.log" || fail "the audit read a build output: $path"
done

# 3. One real, unexpected network call in shipping source still fails.
put apps/agent/src/sneaky_upload.rs 'pub fn send(body: &str) { let _ = reqwest::blocking::Client::new().post("https://example.com").body(body.to_owned()).send(); }'
if audit "$WORK/sneaky.log"; then
    fail "an unexpected network call in shipping source passed"
fi
grep -q 'apps/agent/src/sneaky_upload.rs *UNEXPECTED' "$WORK/sneaky.log" ||
    fail "the unexpected file is not named: $(grep -E 'UNEXPECTED|FAIL' "$WORK/sneaky.log" | head -3)"
grep -q 'EGRESS AUDIT FAIL' "$WORK/sneaky.log" || fail "the audit does not say FAIL"
rm "$TREE/apps/agent/src/sneaky_upload.rs"

# 4. In a git checkout, source tracked under a build-output name fails.
put apps/agent/src/build/upload.rs 'pub fn send() { let _ = reqwest::blocking::get("https://example.com"); }'
(
    cd "$TREE"
    git init -q .
    git -c user.name=test -c user.email=test@example.invalid add apps/agent/src/build/upload.rs
) > /dev/null
if audit "$WORK/tracked.log"; then
    fail "network code tracked under a build-output folder name passed"
fi
grep -q 'FAIL no tracked source under a skipped build-output folder' "$WORK/tracked.log" ||
    fail "the hidden source is not reported: $(grep -E 'FAIL' "$WORK/tracked.log" | head -3)"
grep -Fq 'apps/agent/src/build/upload.rs' "$WORK/tracked.log" || fail "the hidden file is not named"

echo "ok: no-egress.sh passes a clean and a built tree, and fails real or hidden network code"
