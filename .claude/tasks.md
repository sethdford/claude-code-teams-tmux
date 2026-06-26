# Tasks — Project-Type Auto-Detection & Optimal Template Selector

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-698

## Checklist
- [ ] Task 1: Read & lock the public contract of `project_recommend_template` / `project_detect_all`
- [ ] Task 2: Create `scripts/sw-detect.sh` (report + `--json` + `--help`/`--version`, subshell path handling)
- [ ] Task 3: Add guarded source of `lib/project-detect.sh` in `daemon-triage.sh`
- [ ] Task 4: Replace blind score fallback with confidence-gated project-aware selection (≥75 → detected template)
- [ ] Task 5: Register `detect)` dispatch case + help line in `scripts/sw`
- [ ] Task 6: Emit `detect.completed` and `daemon.project_template` events
- [ ] Task 7: Write `scripts/sw-detect-test.sh` using `lib/test-helpers.sh`
- [ ] Task 8: Add selector-contract assertions to `sw-project-detect-test.sh`
- [ ] Task 9: Register `sw-detect-test.sh` in `package.json` `"test"` chain
- [ ] Task 10: Update `.claude/CLAUDE.md` command table + templates note
- [ ] Task 11: Verify `VERSION` consistency (`shipwright version check`)
- [ ] Task 12: Run `sw-detect-test.sh` + `sw-project-detect-test.sh`, then `npm test`
- [ ] `shipwright detect` prints a correct human report for this repo (node/vitest/npm)
- [ ] `shipwright detect --json` emits valid JSON parseable by `jq` with stable keys (`type`, `recommended_template.{template,confidence,reason}`)
- [ ] `select_pipeline_template()` uses the project recommendation when confidence ≥ 75, else preserves the existing score map
- [ ] Selector degrades to current behavior when the detection lib/function is absent (no regression)
- [ ] `detect.completed` and `daemon.project_template` events emitted
- [ ] New test suite passes and is registered in `package.json`
- [ ] All existing tests pass (`npm test`) — **spec acceptance criterion**
- [ ] `shipwright version check` passes (VERSION synced)

## Notes
- Generated from pipeline plan at 2026-06-26T01:50:23Z
- Pipeline will update status as tasks complete
