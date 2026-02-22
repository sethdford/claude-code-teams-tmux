# Tasks — Cost-per-issue tracking and optimization dashboard

## Status: In Progress
Pipeline: standard | Branch: feat/cost-per-issue-tracking-and-optimization-139

## Checklist
- [ ] Task 1: Add `PER_ISSUE_FILE` constant and `_ensure_per_issue_file()` helper
- [ ] Task 2: Implement `cost_record_per_issue()` with upsert logic and atomic writes
- [ ] Task 3: Implement `cost_show_per_issue()` with summary stats (median, p95, most expensive)
- [ ] Task 4: Add `--json` output mode to `cost_show_per_issue()`
- [ ] Task 5: Add `per-issue` subcommand to CLI router
- [ ] Task 6: Update `show_help()` with new command documentation
- [ ] Task 7: Wire `cost_record_per_issue()` into `sw-pipeline.sh` finalize section
- [ ] Task 8: Create `sw-cost-per-issue-test.sh` with 10+ test cases
- [ ] Task 9: Register test suite in `package.json`
- [ ] Task 10: Run tests and verify all pass

## Notes
- Generated from pipeline plan at 2026-02-22T07:34:01Z
- Pipeline will update status as tasks complete
