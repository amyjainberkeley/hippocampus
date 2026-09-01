#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d -t hippocampus-sparkle-keygen)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_TOOL="$TMP_ROOT/generate_keys"
cat >"$FAKE_TOOL" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_GENERATE_KEYS_LOG"
case " $* " in
    *" -x "*)
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == "-x" ]]; then printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' >"$2"; exit 0; fi
            shift
        done
        ;;
    *" -p "*) printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'; exit 0 ;;
    *) exit 0 ;;
esac
FAKE
chmod +x "$FAKE_TOOL"

export HOME="$TMP_ROOT/home"
export FAKE_GENERATE_KEYS_LOG="$TMP_ROOT/invocations.log"
export SPARKLE_GENERATE_KEYS="$FAKE_TOOL"
mkdir -p "$HOME"

printf 'y\n' | "$SCRIPT_DIR/sparkle-keygen.sh" >"$TMP_ROOT/output.log"

PRIVATE_KEY="$HOME/.hippocampus-sparkle-private.key"
PUBLIC_KEY="$HOME/.hippocampus-sparkle-public.key"
[[ -s "$PRIVATE_KEY" ]]
[[ -s "$PUBLIC_KEY" ]]
[[ "$(stat -f '%Lp' "$PRIVATE_KEY")" == "600" ]]
[[ "$(cat "$PUBLIC_KEY")" == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ]]

grep -Fq -- '--account ai.hippocampus.release' "$FAKE_GENERATE_KEYS_LOG"
grep -Fq -- '--account ai.hippocampus.release -x' "$FAKE_GENERATE_KEYS_LOG"
grep -Fq -- '--account ai.hippocampus.release -p' "$FAKE_GENERATE_KEYS_LOG"
if grep -Fq -- ' -f ' "$FAKE_GENERATE_KEYS_LOG"; then
    echo 'FAIL: key generator used Sparkle import mode while creating a key' >&2
    exit 1
fi

echo 'PASS: Sparkle key generator follows the bundled generate_keys contract'
