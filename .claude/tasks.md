# Tasks — Detect Divergent Build-Loop Failures and Terminate Early

## Status: In Progress
Pipeline: standard | Branch: ci/detect-divergent-build-loop-failures-and-1582

## Checklist
- [ ] Task 1: Extract `_progress_insertions()` from `check_progress` in `loop-convergence.sh` (identical semantics)
- [ ] Task 2: Implement `_divergence_hash()` with normalization + `shasum`/`sha256sum`/`cksum` fallback chain
- [ ] Task 3: Implement `record_divergence_sample()` (append-only tracking, counter increment/reset)
- [ ] Task 4: Implement `check_divergence()` + `_divergence_reset()`, writing `divergence.json` atomically and emitting `loop.divergence_detected`
- [ ] Task 5: Wire config vars, `--divergence-threshold` / `--no-divergence` flags, and help text into `sw-loop.sh`
- [ ] Task 6: Call `check_divergence` before `check_circuit_breaker`; call `record_divergence_sample` after `check_progress`; reset at loop init and on session restart
- [ ] Task 7: Add the `divergent_failure` arm to the `show_summary` status table
- [ ] Task 8: Register `loop.divergence_detected` in `config/event-schema.json`; verify with `sw-event-schema-sync.sh`
- [ ] Task 9: Classify divergence in `pipeline-stages-build.sh` → `failure-reason.txt`, ahead of the context-exhaustion sniff
- [ ] Task 10: Add the `divergent_failure` class + retry budget to `daemon-failure.sh`
- [ ] Task 11: Surface divergent aborts in `shipwright cost show` (text + `--json`)
- [ ] Task 12: Surface divergent aborts in `shipwright daemon metrics` (text + `--json`)
- [ ] Task 13: Add 11 divergence assertions to `scripts/sw-loop-test.sh`
- [ ] Task 14: Update `.claude/CLAUDE.md` Loop Configuration table and abort-reason docs
- [ ] Task 15: Run `bash -n` + shellcheck on touched scripts and the full `npm test` suite; confirm zero regressions
- [ ] `sw-loop.sh` tracks an `error-summary.json` signature hash **and** changed-line count for every iteration, persisted to `$LOG_DIR/divergence-agent-N.txt`
- [ ] The loop aborts with `STATUS="divergent_failure"` — distinct from `circuit_breaker` — when the signature repeats `loop.divergence_threshold` times (default 3) with insertions ≤ `loop.divergence_progress_lines` (default 2)
- [ ] `loop.divergence_detected` is emitted, registered in `config/event-schema.json`, and `sw-event-schema-sync.sh` reports no drift
- [ ] `divergence.json` is written atomically (tmp + `mv`, `jq --arg`) and consumed by `pipeline-stages-build.sh` → `failure-reason.txt=divergent_failure`
- [ ] `classify_failure` returns `divergent_failure` (not `context_exhaustion`) for a divergent run, with its own retry budget

## Notes
- Generated from pipeline plan at 2026-08-08T02:37:40Z
- Pipeline will update status as tasks complete
