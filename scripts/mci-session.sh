#!/usr/bin/env bash
# MCI build session bootstrap.
# One command: persistent tmux session, 3 panes, Claude Code already in the
# MCI repo. Re-run to re-attach (idempotent). The session self-briefs from
# CLAUDE.md -> docs/STATE.md, so you never re-explain the project.
set -euo pipefail

SESSION="mci"
REPO="$HOME/Documents/GitHub/mci"

command -v tmux >/dev/null || { echo "tmux not installed: brew install tmux"; exit 1; }
[ -d "$REPO/.git" ] || { echo "MCI repo not found at $REPO"; exit 1; }
cd "$REPO"

# Already running -> just attach.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  exec tmux attach -t "$SESSION"
fi

tmux new-session -d -s "$SESSION" -c "$REPO" -n build
P1=$(tmux list-panes -t "$SESSION":build -F '#{pane_id}' | head -1)

# Pane 1 (left): Claude Code in the repo. It auto-loads CLAUDE.md, whose
# START HERE block points it at docs/STATE.md — full context, no re-brief.
tmux send-keys -t "$P1" "claude" C-m

# Pane 2 (top-right): live PR + commit watch.
P2=$(tmux split-window -h -t "$P1" -c "$REPO" -P -F '#{pane_id}')
tmux send-keys -t "$P2" "watch -n 30 'gh pr list -R amyjainberkeley/hippocampus 2>/dev/null; echo; git log --oneline -8'" C-m

# Pane 3 (bottom-right): scratch shell, prints where we are on open.
P3=$(tmux split-window -v -t "$P2" -c "$REPO" -P -F '#{pane_id}')
tmux send-keys -t "$P3" "head -n 26 docs/STATE.md; echo; echo '^ current state. Review diffs / merge PRs here (human-only merges).'" C-m

tmux select-pane -t "$P1"
exec tmux attach -t "$SESSION"
