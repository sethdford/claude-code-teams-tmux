# Tasks — Adaptive Build-Loop Iteration Budget from Historical Outcomes

## Status: In Progress
Pipeline: standard | Branch: feat/adaptive-build-loop-iteration-budget-fro-1502

## Checklist
- [ ] Task 1: Create `scripts/lib/adaptive-iterations.sh` — load guard, `VERSION=3.3.0`, tunables
- [ ] Task 2: Implement `adaptive_iterations_cohort` (bash 3.2 safe, always returns a key)
- [ ] Task 3: Implement `_iter_samples_for_cohort` with `fromjson? // empty` malformed-line tolerance
- [ ] Task 4: Implement `_iter_samples_global` (job_id group-by over `loop.iteration_complete`)
- [ ] Task 5: Implement `_iter_percentile` in awk (no `sort` pipeline)
- [ ] Task 6: Implement `adaptive_iterations_suggest` — 3-tier fallback + asymmetric clamping
- [ ] Task 7: Implement `adaptive_iterations_record_outcome` + `adaptive_iterations_explain`
- [ ] Task 8: Wire into `sw-loop.sh` — source, `--adaptive-iterations` flag, `apply_adaptive_budget()` hook, outcome emit, help text
- [ ] Task 9: Write `scripts/sw-adaptive-iterations-test.sh` (18 unit tests, table below)
- [ ] Task 10: Add flag-exists + default-off assertions to `sw-loop-test.sh`
- [ ] Task 11: Regenerate `config/event-schema.json` via `sw-event-schema-sync.sh --write`
- [ ] Task 12: Document in `.claude/CLAUDE.md` (config table + cold-start caveat)
- [ ] Task 13: Run new suite + `sw-loop-test.sh` + full `npm test`
- [ ] Task 14: `shellcheck` clean; `shipwright version check` passes
- [ ] `adaptive_iterations_suggest` returns a history-derived budget for a well-sampled cohort and the unmodified static default when history is absent, empty, malformed, or under-sampled — **AC #1**
- [ ] `shipwright loop --adaptive-iterations` enables it; `loop.adaptive_iterations` in `daemon-config.json` enables it; **default is off** and `git diff` shows no behavior change on any existing path when unset — **AC #2**
- [ ] All 18 unit tests pass, covering no-history fallback, sufficient-history adjustment, and malformed/missing file degradation — **AC #3**
- [ ] `loop.budget_selected` (cohort, budget, default, source tier, sample count) and `loop.budget_outcome` (cohort, iterations, converged, budget) appear in `events.jsonl` and are registered in `config/event-schema.json` — **AC #4**
- [ ] `--max-iterations N` given explicitly still wins — `MAX_ITERATIONS_EXPLICIT` honored
- [ ] `npm test` green (all auto-discovered suites); `shellcheck` clean; bash 3.2 constructs only

## Notes
- Generated from pipeline plan at 2026-08-07T18:39:45Z
- Pipeline will update status as tasks complete
