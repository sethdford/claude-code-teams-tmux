# Tasks — Pre-Build Validation Engine — Catch Failures Before Wasting Iterations

## Status: In Progress
Pipeline: standard | Branch: feat/pre-build-validation-engine-catch-failur-622

## Checklist
- [ ] Task 1: Scaffold `pipeline-prebuild-validation.sh` (load-guard, `VERSION`, `set -u`-safe globals, no-op dependency fallbacks). *(blocks 2–11)*
- [ ] Task 2: Implement config readers (enabled/timeout/on_failure/checks parser with env override). *(blocked by 1)*
- [ ] Task 3: Implement `_prebuild_changed_files` scope computation with goal-branch fallback + cap. *(blocked by 1)*
- [ ] Task 4: Implement `required_files` check (critical).
- [ ] Task 5: Implement `syntax` check (`node --check` / `bash -n`, language-aware, critical).
- [ ] Task 6: Implement `imports` check (relative-specifier resolution, heuristic critical).
- [ ] Task 7: Implement `smoke_test` check (configurable cmd, soft + timeout-aware, argv not eval).
- [ ] Task 8: Implement `_prebuild_run_check` (per-check `_timeout` + ms timing). *(blocked by 4–7)*
- [ ] Task 9: Implement `prebuild_validate` orchestrator (ordering, stop-on-critical, global budget, degrade-safe). *(blocked by 2,3,8)*
- [ ] Task 10: Implement atomic `_prebuild_write_report` with `time_saved` calc.
- [ ] Task 11: Implement `_prebuild_emit_metrics` (events.jsonl + pipeline-state summary).
- [ ] Task 12: Source the lib in `pipeline-stages.sh`. *(blocked by 1)*
- [ ] Task 13: Inject guarded `prebuild_validate` call into `self_healing_build_test()`. *(blocked by 9, 12)*
- [ ] Task 14: Add `validation` block to `daemon-config.json` + shipped defaults.
- [ ] Task 15: Write `sw-prebuild-validation-test.sh`, register in `package.json`. *(blocked by 1–11)*
- [ ] Task 16: Update `.claude/CLAUDE.md` and run docs sync.
- [ ] `prebuild_validate` runs before the build/test cycle loop and completes within the configured budget (default 60s).
- [ ] Checks implemented: `required_files`, `syntax`, `imports`, `smoke_test`; ordered cheap→expensive; stop-on-first-critical.
- [ ] Critical failure writes `.claude/validation-report.json` (atomic) and skips the build loop (`mark_stage_failed build`, `return 1`).
- [ ] Results logged to `pipeline-state.md` and `events.jsonl` (`validation.complete` + per-check events).

## Notes
- Generated from pipeline plan at 2026-06-11T13:45:18Z
- Pipeline will update status as tasks complete
