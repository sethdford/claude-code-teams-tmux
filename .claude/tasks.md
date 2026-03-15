# Tasks — Extract Hardcoded Timeouts from sw-daemon.sh to policy.json

## Status: In Progress
Pipeline: standard | Branch: refactor/extract-hardcoded-timeouts-from-sw-daemo-280

## Checklist
- [ ] Task 1: Add `daemon.timeouts` section to `config/policy.json` with all 11 default values
- [ ] Task 2: Add schema validation for `daemon.timeouts` in `config/policy.schema.json`
- [ ] Task 3: Update `rotate_event_log()` to read from policy (2 values)
- [ ] Task 4: Update `gh_retry()` to read retry config from policy (3 values)
- [ ] Task 5: Update SIGTERM grace wait in shutdown handler (1 value)
- [ ] Task 6: Update graceful shutdown loop to read from policy (3 values)
- [ ] Task 7: Update watchdog backoff to read from policy (2 values)
- [ ] Task 8: Add test cases for custom timeout configuration
- [ ] Task 9: Run full test suite to verify no regressions
- [ ] Task 10: Validate policy.json with `jq empty config/policy.json`
- [ ] All 11 hardcoded timeout values in sw-daemon.sh read from `config/policy.json` via `policy_get()`
- [ ] Each value falls back to the original hardcoded constant when config is absent
- [ ] `config/policy.json` contains `daemon.timeouts` section with documented defaults
- [ ] `config/policy.schema.json` validates the new section with min/max ranges
- [ ] `npm test` passes (all existing tests green, no regressions)
- [ ] Daemon behavior is identical when using default values (zero behavior change)
- [ ] Platform health scan shows ~11 fewer hardcoded values

## Notes
- Generated from pipeline plan at 2026-03-15T02:49:11Z
- Pipeline will update status as tasks complete
