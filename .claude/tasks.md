# Tasks — Intelligent Retry Strategy Engine with Failure Pattern Recognition

## Status: In Progress
Pipeline: standard | Branch: feat/intelligent-retry-strategy-engine-with-f-627

## Checklist
- [ ] Task 1: Scaffold `scripts/lib/retry-strategy.sh` (module guard, `VERSION`, defensive helper/`now_iso` fallbacks).
- [ ] Task 2: Implement `retry_category_of()` 4-category mapping.
- [ ] Task 3: Implement `retry_classify()` (delegate to `recovery_classify_error`, inline fallback).
- [ ] Task 4: Implement `retry_memory_lookup()` (guarded `memory_query_fix_for_error` wrapper).
- [ ] Task 5: Implement `retry_compute_confidence()` (integer math, clamp, `printf` float format).
- [ ] Task 6: Implement `retry_escalation_target()` (config-driven ladder, bounded).
- [ ] Task 7: Implement `retry_decide()` + `retry.decision` event (JSON via `jq -n --arg`).
- [ ] Task 8: Implement `retry_record_outcome()` + atomic metrics JSONL + `retry.outcome` + `memory_track_fix`.
- [ ] Task 9: Add guarded CLI dispatch (`decide|classify|category|record|metrics`).
- [ ] Task 10: Integrate into `daemon-failure.sh` + `sw-daemon.sh`; add `retry_strategy` config defaults.
- [ ] Task 11: Integrate into `sw-loop.sh` + `loop-restart.sh` (guarded calls + outcome recording).
- [ ] Task 12: Write `scripts/sw-retry-strategy-test.sh` (unit + integration + E2E).
- [ ] Task 13: Register test in `package.json`; run new + touched suites (all `FAIL=0`).
- [ ] Task 14: Update `.claude/CLAUDE.md`; confirm `shipwright version check` passes.
- [ ] `scripts/lib/retry-strategy.sh` exists, `set -euo pipefail`-compatible, module guard, `VERSION` matching `package.json`, bash 3.2 compatible (no `declare -A`, `readarray`, `${var,,}`, `${var^^}`).
- [ ] Failure classification maps every error into exactly one of: `recoverable-transient`, `recoverable-escalation`, `context-exhausted`, `unrecoverable`.
- [ ] `retry_decide` outputs valid JSON (`jq -e .` passes) with `action` ∈ {`immediate`,`model-escalation`,`session-restart`,`skip`} and `confidence` ∈ [0.05, 0.99].
- [ ] Memory integration queries past failures by error signature, raises confidence / surfaces a fix on high-effectiveness matches, and degrades to empty gracefully when memory/jq absent.
- [ ] Escalation ladder implemented (same → sonnet → opus → session-restart → human), bounded by `max_attempts`.
- [ ] `sw-loop.sh` (+`loop-restart.sh`) and `daemon-failure.sh` (+`sw-daemon.sh`) invoke `retry_decide` before retry attempts, guarded so absence of the lib is non-fatal.

## Notes
- Generated from pipeline plan at 2026-06-11T13:45:07Z
- Pipeline will update status as tasks complete
