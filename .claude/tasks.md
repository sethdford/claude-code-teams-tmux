# Tasks — Pipeline Failure Auto-Diagnostic Report Generator

## Status: In Progress
Pipeline: standard | Branch: ci/pipeline-failure-auto-diagnostic-report-231

## Checklist
- [ ] Task 1: Create `scripts/lib/pipeline-diagnostic.sh` with module guard, `classify_failure_type()`, and `suggest_remediation()` functions
- [ ] Task 2: Implement `generate_failure_report()` — git state, timeline, stage logs, error-log.jsonl sections
- [ ] Task 3: Implement `append_failure_summary()` to update pipeline-state.md
- [ ] Task 4: Add `emit_event "diagnostic.report"` with failure classification in the report function
- [ ] Task 5: Source `pipeline-diagnostic.sh` from `pipeline-execution.sh`
- [ ] Task 6: Hook `generate_failure_report` call into `pipeline-commands.sh` failure path
- [ ] Task 7: Create `scripts/sw-failure-report-test.sh` with test harness setup and mock environment
- [ ] Task 8: Write tests for `classify_failure_type` (all 7 failure types)
- [ ] Task 9: Write tests for `generate_failure_report` (report file exists, contains expected sections)
- [ ] Task 10: Write tests for graceful degradation (missing logs, empty error-log)
- [ ] Task 11: Write test for event emission and pipeline-state summary append
- [ ] Task 12: Register test suite in `package.json`
- [ ] Task 13: Run full test suite to verify no regressions

## Notes
- Generated from pipeline plan at 2026-03-08T04:59:29Z
- Pipeline will update status as tasks complete
