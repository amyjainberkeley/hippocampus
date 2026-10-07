#!/usr/bin/env bash
# End-to-end proof of the handoff layer with real agents.
#
# What it proves: a Claude Code session and a Codex session that happen in a
# project leave transcripts on disk; Hippocampus imports them; the NEXT session
# of either agent in that project starts with a handoff packet and can answer
# "where did we leave off?" without being told.
#
# It uses the real ~/.claude and ~/.codex configuration (the hooks that
# `mci-agent connect --all` installs) and the real brain, because that is the
# product path. It adds a handful of events about a throwaway project named
# after a timestamp. Requires: a logged-in `claude` and `codex`, and a built
# mci-agent (pass its path as $1 or set MCI_AGENT).
#
# Usage: scripts/e2e-handoff.sh [/path/to/mci-agent]
#
# Codex runs with -s read-only, approval_policy=never, stdin closed and hook
# trust bypassed: without those, `codex exec` waits forever on stdin or an
# approval, and a hooks.json it has not been asked to trust is silently skipped.
# On a real machine you trust the Hippocampus hook once, interactively.

set -euo pipefail

AGENT="${1:-${MCI_AGENT:-mci-agent}}"
command -v "$AGENT" >/dev/null 2>&1 || { [ -x "$AGENT" ] || { echo "mci-agent not found: $AGENT" >&2; exit 2; }; }
command -v claude >/dev/null || { echo "claude CLI not found" >&2; exit 2; }
command -v codex >/dev/null || { echo "codex CLI not found" >&2; exit 2; }

STAMP="$(date +%Y%m%d%H%M%S)"
TOKEN="zebrafish$STAMP"
PROJ="${TMPDIR:-/tmp}/handoff-e2e-$STAMP"
mkdir -p "$PROJ" && cd "$PROJ" && git init -q . && printf '# %s\n' "$TOKEN" > README.md && git add README.md && git -c user.email=e2e@local -c user.name=e2e commit -q -m "init $TOKEN"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$*"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$*"; }

echo "== project $PROJ (token $TOKEN)"

# 1. A first Claude Code session that leaves a decision and a next step.
echo "== 1. seed session (Claude Code)"
claude -p "We are building a tiny CLI called $TOKEN. Decision: we will use SQLite, not Postgres, because it ships as one file. Next step: write the schema file schema.sql with a table named ${TOKEN}_runs. Do not create any files now. Reply with exactly: NOTED." \
  --output-format text --model claude-sonnet-5 >/dev/null 2>&1 && ok "seed session ran" || bad "seed session failed"

# 2. Import it.
echo "== 2. refresh"
"$AGENT" refresh --budget-ms 20000 >/dev/null 2>&1 && ok "refresh ran" || bad "refresh failed"

# 3. The packet for this project names the decision and the next step.
echo "== 3. packet"
PACKET="$("$AGENT" handoff --cwd "$PROJ" --no-refresh --format markdown 2>/dev/null || true)"
printf '%s\n' "$PACKET" | sed 's/^/    | /' | head -40
printf '%s' "$PACKET" | grep -qi "sqlite"   && ok "packet mentions the SQLite decision" || bad "packet lacks the SQLite decision"
printf '%s' "$PACKET" | grep -qi "schema"   && ok "packet mentions the schema next step" || bad "packet lacks the next step"
printf '%s' "$PACKET" | grep -q  "event "   && ok "packet cites events" || bad "packet has no citations"
WORDS="$(printf '%s' "$PACKET" | wc -w | tr -d ' ')"
[ "$WORDS" -le 700 ] && ok "packet is $WORDS words" || bad "packet is $WORDS words (budget)"

# 4. A fresh Claude Code session, told nothing, answers from the hook.
echo "== 4. fresh Claude Code session"
ANSWER="$(claude -p "Without reading any files: in one line, what database did we decide on for this project and what is the next step?" --output-format text --model claude-sonnet-5 2>/dev/null || true)"
printf '    > %s\n' "$ANSWER"
printf '%s' "$ANSWER" | grep -qi "sqlite" && ok "Claude Code knew the decision" || bad "Claude Code did not know the decision"
printf '%s' "$ANSWER" | grep -qi "schema" && ok "Claude Code knew the next step" || bad "Claude Code did not know the next step"

# 5. A fresh Codex session, told nothing, answers from its hook.
echo "== 5. fresh Codex session"
CANSWER="$(codex exec --dangerously-bypass-hook-trust -s read-only -c 'approval_policy="never"' --skip-git-repo-check "Without reading any files: in one line, what database did we decide on for this project and what is the next step?" </dev/null 2>/dev/null | tail -3 || true)"
printf '    > %s\n' "$CANSWER"
printf '%s' "$CANSWER" | grep -qi "sqlite" && ok "Codex knew the decision" || bad "Codex did not know the decision"

# 6. Delivery receipts exist for both clients.
echo "== 6. doctor"
DOC="$("$AGENT" doctor 2>/dev/null || true)"
printf '%s\n' "$DOC" | grep -i "delivery" | sed 's/^/    | /'
printf '%s' "$DOC" | grep -qi "claude-code" && ok "doctor reports Claude Code delivery" || bad "doctor missing Claude Code delivery"
printf '%s' "$DOC" | grep -qi "codex"       && ok "doctor reports Codex delivery" || bad "doctor missing Codex delivery"

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
