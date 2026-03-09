# Pipeline Tasks — Pipeline Dry-Run Mode for Execution Plan Validation

## Implementation Checklist
- [ ] Task 1: Add `DRY_RUN_JSON` flag parsing to `scripts/lib/pipeline-cli.sh` and update help text
- [ ] Task 2: Add `_dry_run_fmt_duration()` helper function to `pipeline-commands.sh`
- [ ] Task 3: Add `_dry_run_stage_token_estimate()` helper function for per-stage token estimates
- [ ] Task 4: Add `_dry_run_model_cost_rate()` and `_dry_run_get_stage_timeout()` helpers
- [ ] Task 5: Enhance stage table with timeout column in `run_dry_run()`
- [ ] Task 6: Add per-stage cost breakdown section to `run_dry_run()`
- [ ] Task 7: Add configuration validation section with semantic checks
- [ ] Task 8: Add intelligence skip predictions section
- [ ] Task 9: Add budget status section reading from `~/.shipwright/budget.json`
- [ ] Task 10: Add summary section replacing simple pass/fail message
- [ ] Task 11: Implement JSON output mode (`--json` flag) using `jq -n`
- [ ] Task 12: Add `test_dry_run_shows_timeouts` test
- [ ] Task 13: Add `test_dry_run_shows_per_stage_cost` test
- [ ] Task 14: Add `test_dry_run_validates_config` test
- [ ] Task 15: Add `test_dry_run_shows_summary` and `test_dry_run_json_output` tests
- [ ] Task 16: Run full test suite and fix any regressions
- [ ] `shipwright pipeline start --goal "test" --dry-run` shows per-stage cost table with token counts and USD
- [ ] `shipwright pipeline start --goal "test" --dry-run` shows per-stage timeout (default + adaptive)
- [ ] `shipwright pipeline start --goal "test" --dry-run` shows intelligence skip predictions
- [ ] `shipwright pipeline start --goal "test" --dry-run` performs semantic config validation (stage ordering, gate values)

## Context
- Pipeline: autonomous
- Branch: ci/issue-239
- Issue: none
- Generated: 2026-03-09T06:23:02Z
