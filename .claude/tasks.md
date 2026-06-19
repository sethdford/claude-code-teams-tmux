# Tasks — Intelligence Feature Impact Analyzer with A/B Test Framework

## Status: In Progress
Pipeline: standard | Branch: feat/intelligence-feature-impact-analyzer-wit-661

## Checklist
- [ ] Task 1: Scaffold `sw-intelligence-impact.sh` header + `ensure_store`
- [ ] Task 2: Implement `record` with input validation + atomic append (blocks 5,6,7,9,10)
- [ ] Task 3: Implement `compute_cohort_stats` + `score_features` (impact/ROI) (blocks 4,5,6)
- [ ] Task 4: Implement `analyze` (cohort comparison, `--json`)
- [ ] Task 5: Implement `report` (monthly window, per-feature ROI, recommendations)
- [ ] Task 6: Implement `apply` (n≥20 gate, backup + atomic config auto-disable + explanation note)
- [ ] Task 7: Implement `run-pair` active paired harness
- [ ] Task 8: Add best-effort `record` hook in `lib/pipeline-execution.sh`
- [ ] Task 9: Wire `impact)` dispatch + help into `sw-intelligence.sh`
- [ ] Task 10: Write `.claude/docs/intelligence-validation.md`
- [ ] Task 11: Write `sw-intelligence-impact-test.sh` (unit + integration)
- [ ] Task 12: Register test in `package.json`; `shipwright docs sync`
- [ ] Task 13: Run new + affected suites to green
- [ ] Task 14: `shipwright version check` (VERSION sync)
- [ ] `shipwright intelligence impact` dispatches to the new module; `analyze`/`report`/`record`/`run-pair`/`apply`/`status`/`help` all work.
- [ ] A/B harness (`run-pair`) runs an identical issue twice (intel on/off) and records both variants with a shared `experiment_id`.
- [ ] Measures + reports success rate, total duration, cost, iteration count, and failure-type breakdown per cohort.
- [ ] Enforces the n≥20-per-cohort significance gate before any auto-disable.
- [ ] `report` outputs per-feature impact scores, ROI, and KEEP/DISABLE/INCONCLUSIVE recommendations; supports `--json`.
- [ ] `apply` auto-disables negative-ROI features in `daemon-config.json` with an explanatory note + backup; `--dry-run` makes no changes.

## Notes
- Generated from pipeline plan at 2026-06-19T01:31:58Z
- Pipeline will update status as tasks complete
