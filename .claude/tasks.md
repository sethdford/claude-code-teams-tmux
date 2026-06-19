# Tasks — Cost Impact Preview & Budget-Aware Template Selector

## Status: In Progress
Pipeline: standard | Branch: feat/cost-impact-preview-budget-aware-templat-670

## Checklist
- [ ] Task 1: `cp_record_estimate` / `cp_record_actual` with atomic flock append
- [ ] Task 2: `cp_history_median` with ±5 complexity band + time decay
- [ ] Task 3: Blend history into `cp_estimate_template`; bump `CP_VERSION`
- [ ] Task 4: `cost accuracy` subcommand (table + `--json`)
- [ ] Task 5: `--auto-template` flag (parse + default + help)
- [ ] Task 6: Pipeline-start preview + budget check + auto-select wiring
- [ ] Task 7: Record estimate at start, actual at finalize, emit accuracy event
- [ ] Task 8: Tests for history, blend, accuracy, auto-template (mocked)
- [ ] Task 9: Dashboard `/api/cost/preview` endpoint + cost card (best-effort)
- [ ] Task 10: Docs (`CLAUDE.md`) + discoverability verification
- [ ] `cp_estimate_template` blends historical data when available and falls back to the static model when not.
- [ ] `cost preview` / `cost select` keep working; `cost accuracy` reports estimate-vs-actual error.
- [ ] `pipeline start --auto-template` selects a budget-aware template and prints a cost preview before running.
- [ ] An over-budget estimate triggers a downgrade suggestion / warning (respecting `--ignore-budget`).
- [ ] Estimated and actual costs are recorded to `cost-history.jsonl`; a `cost.estimate_accuracy` event is emitted at finalize.
- [ ] All existing 33 cost-preview tests pass; new tests cover history, blend, accuracy, and `--auto-template`.
- [ ] `bash -n` clean on all modified scripts; bash 3.2 constraints honored; atomic writes used.
- [ ] `.claude/CLAUDE.md` documents the flag, `cost accuracy`, and the new runtime-state file; feature is discoverable via `shipwright cost --help`.

## Notes
- Generated from pipeline plan at 2026-06-19T19:08:26Z
- Pipeline will update status as tasks complete
