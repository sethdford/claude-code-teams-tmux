# Pipeline Tasks — Intelligence Feature Impact Analyzer with A/B Test Framework

## Implementation Checklist
- [x] Task 1: Scaffold `sw-intelligence-impact.sh` header + `ensure_store`
- [x] Task 2: Implement `record` with input validation + atomic append (blocks 5,6,7,9,10)
- [x] Task 3: Implement `compute_cohort_stats` + `score_features` (impact/ROI) (blocks 4,5,6)
- [x] Task 4: Implement `analyze` (cohort comparison, `--json`)
- [x] Task 5: Implement `report` (monthly window, per-feature ROI, recommendations)
- [x] Task 6: Implement `apply` (n≥20 gate, backup + atomic config auto-disable + explanation note)
- [x] Task 7: Implement `run-pair` active paired harness
- [x] Task 8: Add best-effort `record` hook in `lib/pipeline-execution.sh`
- [x] Task 9: Wire `impact)` dispatch + help into `sw-intelligence.sh`
- [x] Task 10: Write `.claude/docs/intelligence-validation.md`
- [x] Task 11: Write `sw-intelligence-impact-test.sh` (unit + integration)
- [x] Task 12: Register test in `package.json`; `shipwright docs sync`
- [x] Task 13: Run new + affected suites to green
- [x] Task 14: `shipwright version check` (VERSION sync)
- [x] `shipwright intelligence impact` dispatches to the new module; `analyze`/`report`/`record`/`run-pair`/`apply`/`status`/`help` all work.
- [x] A/B harness (`run-pair`) runs an identical issue twice (intel on/off) and records both variants with a shared `experiment_id`.
- [x] Measures + reports success rate, total duration, cost, iteration count, and failure-type breakdown per cohort.
- [x] Enforces the n≥20-per-cohort significance gate before any auto-disable.
- [x] `report` outputs per-feature impact scores, ROI, and KEEP/DISABLE/INCONCLUSIVE recommendations; supports `--json`.
- [x] `apply` auto-disables negative-ROI features in `daemon-config.json` with an explanatory note + backup; `--dry-run` makes no changes.

## Context
- Pipeline: standard
- Branch: feat/intelligence-feature-impact-analyzer-wit-661
- Issue: #661
- Generated: 2026-06-19T01:31:57Z
