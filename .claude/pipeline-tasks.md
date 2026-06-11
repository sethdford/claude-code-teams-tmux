# Pipeline Tasks — Intelligent Retry Strategy Engine with Failure Pattern Recognition

## Implementation Checklist
- [ ] Task 1: Add `RETRY_NOTIFY_STATE` + `retry_should_notify_human` + `retry_notify_human` to `retry-strategy.sh` (atomic write, jq-guarded) — *blocks Task 3, Task 5*
- [ ] Task 2: In `daemon-failure.sh`, capture `_rs_action` and branch `skip`→terminal / `session-restart`→context-exhaustion boost / else legacy; guard on `retry_strategy.enabled` — *blocks Task 6*
- [ ] Task 3: Wire `max_human_notify_per_issue` enforcement into the daemon `skip→human` path using Task 1 helpers — *depends on Task 1, Task 2*
- [ ] Task 4: Wire `action=session-restart` into `sw-loop.sh` restart hint (reuse `loop-restart.sh`)
- [ ] Task 5: Add unit tests for notify-budget helpers in `sw-retry-strategy-test.sh` — *depends on Task 1*
- [ ] Task 6: Add daemon-failure executor tests (mock `retry_decide`) in `sw-lib-daemon-failure-test.sh` — *depends on Task 2, Task 3*
- [ ] Task 7: Run `sw-retry-strategy-test.sh`, `sw-lib-daemon-failure-test.sh`, `sw-loop-test.sh`; fix regressions
- [ ] Task 8: Run full `npm test`; confirm 0 failures
- [ ] Task 9: Update `.claude/CLAUDE.md` retry section; `docs check`/`sync`; `version check`
- [ ] Task 10: Dry-run verification that `retry.decision`/`retry.outcome`/`retry.human_notify` events land in `events.jsonl`
- [ ] `daemon-failure.sh` acts on `retry_decide`: `skip` terminates retries (count not incremented), `session-restart` takes the context-exhaustion/restart-boost path, others fall through to legacy escalation.
- [ ] `max_human_notify_per_issue` enforced: at most N `retry.human_notify` events per issue; verified by test.
- [ ] `sw-loop.sh` honors `action=session-restart` via the existing restart hint (guarded, non-fatal).
- [ ] New unit + integration tests added; `bash scripts/sw-retry-strategy-test.sh` and `bash scripts/sw-lib-daemon-failure-test.sh` pass with 0 failures.
- [ ] `npm test` passes (all suites, 0 failures).
- [ ] `retry.decision`, `retry.outcome`, `retry.human_notify` events observed in `events.jsonl` during a dry run.
- [ ] All new code is bash 3.2 compatible (no `declare -A`, `readarray`, `${var,,}`), uses `set -euo pipefail`, atomic writes, `jq --arg`, subshell `cd`.
- [ ] `.claude/CLAUDE.md` retry section updated; `shipwright version check` passes.
- [ ] Engine remains fully guarded — `retry_strategy.enabled=false` restores legacy behavior with no regressions.

## Context
- Pipeline: standard
- Branch: feat/intelligent-retry-strategy-engine-with-f-627
- Issue: #627
- Generated: 2026-06-11T21:18:33Z
