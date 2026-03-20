# Tasks — Issue Scope Hard Limit Pre-Flight Validator with Auto-Reject

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-283

## Checklist
- [ ] Task 1: Create `scripts/lib/preflight-scope.sh` with estimation and validation functions
- [ ] Task 2: Add `SKIP_PREFLIGHT_SCOPE=false` default in `sw-pipeline.sh` and `--skip-preflight` flag in `pipeline-cli.sh`
- [ ] Task 3: Integrate scope validation call into `pipeline_start()` in `pipeline-commands.sh` after `gh_init`
- [ ] Task 4: Add `preflight_scope` section to `config/policy.json` with default limits
- [ ] Task 5: Register new event types in `config/event-schema.json`
- [ ] Task 6: Create `scripts/sw-preflight-scope-test.sh` test suite with 18 test cases
- [ ] Task 7: Register test suite in `package.json`
- [ ] Task 8: Run test suite and verify all tests pass
- [ ] `preflight_scope_validate()` correctly rejects issues exceeding any configured limit
- [ ] `preflight_scope_validate()` correctly passes issues within all limits
- [ ] Rejection produces valid JSON in `preflight-rejection.json`
- [ ] Rejection comments on GitHub issue with decomposition guidance (when NO_GITHUB not set)
- [ ] Rejection adds `preflight-rejected` label and removes watch label
- [ ] All limits configurable via `daemon-config.json` or `policy.json`
- [ ] Setting any limit to 0 disables that specific check
- [ ] Setting `enabled: false` disables all scope checks
- [ ] `--skip-preflight` flag bypasses scope validation
- [ ] Events emitted for both pass and reject outcomes
- [ ] Test suite has >= 14 tests with 100% pass rate
- [ ] Existing pipeline tests continue to pass

## Notes
- Generated from pipeline plan at 2026-03-20T13:37:11Z
- Pipeline will update status as tasks complete
