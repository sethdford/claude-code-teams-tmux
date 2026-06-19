# Pipeline Tasks — Cost Impact Preview & Budget-Aware Template Selector

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/cost-preview.sh` scaffold (version, source guards, no side effects on source).
- [ ] Task 2: Implement `_cp_stage_tokens` (Bash 3.2 case map, default fallback).
- [ ] Task 3: Implement `_cp_stage_model` (jq with `--arg`, layered fallback).
- [ ] Task 4: Implement `cp_estimate_template` (enabled-stages-only, awk accumulation, missing-template error path).
- [ ] Task 5: Implement `cp_preview_one` with human + `--json` output.
- [ ] Task 6: Implement `cp_preview_all` (sorted ascending by cost, human + JSON, skip-bad-file).
- [ ] Task 7: Implement `cp_select` budget-aware algorithm + `emit_event`.
- [ ] Task 8: Wire `preview`/`select` subcommands and help text into `sw-cost.sh`.
- [ ] Task 9: Refactor `estimate_cost` in `sw-model-router.sh` to reuse token map (output-compatible).
- [ ] Task 10: Write `scripts/sw-cost-preview-test.sh`.
- [ ] Task 11: Register new test in `package.json`.
- [ ] Task 12: Update `.claude/CLAUDE.md` cost command rows.
- [ ] Task 13: Sync `VERSION` and run `npm test`; confirm green.
- [ ] `cost preview <template> [complexity]`, `cost preview --all`, and `cost select` work and are documented in `show_help` + `.claude/CLAUDE.md`.
- [ ] `--json` output for all three is valid (`jq -e .` exits 0).
- [ ] Estimates respect each template's actual `enabled` stages and per-stage model routing.
- [ ] `cp_select` is budget-aware: unlimited → default; tight → most-capable-that-fits; none → cheapest + warn; emits `cost.template_selected`.
- [ ] New `scripts/sw-cost-preview-test.sh` passes and is registered in `package.json`.
- [ ] `sw-cost-test.sh` and `sw-model-router-test.sh` still pass; full `npm test` green.
- [ ] All new/edited scripts are Bash 3.2 compatible, `set -euo pipefail`, atomic writes, `jq --arg`, `VERSION` synced.

## Context
- Pipeline: autonomous
- Branch: ci/issue-670
- Issue: none
- Generated: 2026-06-19T14:13:17Z
