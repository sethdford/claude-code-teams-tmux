# Tasks — Emergency Conservative Pipeline Template for Maximum Reliability

## Status: In Progress
Pipeline: standard | Branch: ci/emergency-conservative-pipeline-template-234

## Checklist
- [ ] Task 1: Create `templates/pipelines/emergency.json` with all conservative settings
- [ ] Task 2: Validate emergency.json is valid JSON and follows template schema
- [ ] Task 3: Add `emergency` row to Pipeline Templates table in `.claude/CLAUDE.md`
- [ ] Task 4: Add `test_emergency_template_loads` test function in `sw-e2e-smoke-test.sh`
- [ ] Task 5: Register the new test in the test runner section of `sw-e2e-smoke-test.sh`
- [ ] Task 6: Run the test suite to verify template loads and overrides are correct
- [ ] Task 7: Verify `--template emergency` flag works with pipeline start (dry-run)
- [ ] `templates/pipelines/emergency.json` exists and is valid JSON
- [ ] All timeouts doubled from standard (wait_ci_timeout_s: 1200 vs 600)
- [ ] All stages use opus model (`claude-opus-4-6`)
- [ ] Intelligence, prediction, adaptive features disabled via template flags
- [ ] `max_iterations` increased 50% (30 vs standard 20)
- [ ] Auto-merge disabled
- [ ] Only minimal stages enabled (intake → build → test → pr)
- [ ] Documented in CLAUDE.md Pipeline Templates table
- [ ] `--template emergency` flag works with pipeline start command
- [ ] Test suite validates template loads and overrides are applied correctly
- [ ] All existing tests still pass (no regressions)

## Notes
- Generated from pipeline plan at 2026-03-08T14:02:32Z
- Pipeline will update status as tasks complete
