# scripts/check.sh.d — per-lane extension hooks

Reserved for future per-lane tuning. Empty on purpose today.

`scripts/check.sh` (cycle 8.44, runlog architecture study §1) has a fixed lane
table baked in. When we need lane-specific tuning that varies by developer
machine (extra clippy allow-lists on a legacy branch, extra cargo-audit
ignores when a new advisory lands upstream, swiftformat rule overrides), the
plan is to drop a small snippet here — `<lane>.env` or `<lane>.sh` — and have
`check.sh` source it before that lane runs. Not wired up yet; add when the
first concrete need appears rather than building speculative extensibility.

Rule: anything in this directory must be idempotent, side-effect-free at
source time, and never mask a real failure (SKIP is fine; silent PASS is not).
