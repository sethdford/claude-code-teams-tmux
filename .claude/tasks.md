# Tasks — Fallback Pattern Eliminator with Config Migration and Safety Validation

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-348

## Checklist
- [ ] Task 1: Add `stall_detector` and `connect` sections to `config/defaults.json`, add `optimize_interval` and `stale_reaper_interval` to daemon section
- [ ] Task 2: Extend `config/defaults.schema.json` with schemas for all new and existing uncovered sections
- [ ] Task 3: Migrate `scripts/sw-pipeline.sh` -- replace 4 hardcoded fallbacks with `_config_get` calls
- [ ] Task 4: Migrate `scripts/sw-stall-detector.sh` -- replace 4 hardcoded fallbacks with `_config_get` calls
- [ ] Task 5: Migrate `scripts/lib/daemon-poll.sh` -- replace 6 hardcoded fallbacks with `_config_get` calls
- [ ] Task 6: Migrate `scripts/sw-connect.sh` -- replace hardcoded heartbeat interval
- [ ] Task 7: Add `_config_migrate()` function to `scripts/lib/config.sh`
- [ ] Task 8: Create `scripts/sw-config.sh` with validate/show/migrate subcommands
- [ ] Task 9: Register `config` subcommand in `scripts/sw` CLI router
- [ ] Task 10: Update `docs/migration-guide-fallback-config.md` with new sections and CLI commands
- [ ] Task 11: Extend `scripts/sw-config-validate-test.sh` with tests for new sections and migration
- [ ] Task 12: Run full test suite and fix any regressions
- [ ] Task 13: Verify config precedence chain works end-to-end for new keys
- [ ] All `${VAR:-hardcoded}` config patterns in sw-pipeline.sh, sw-stall-detector.sh, lib/daemon-poll.sh, sw-connect.sh replaced with `_config_get` calls
- [ ] `config/defaults.json` contains entries for every config key used across the codebase (stall_detector, connect sections added)
- [ ] `config/defaults.schema.json` covers all sections in defaults.json with type validation
- [ ] `_config_migrate()` function exists and warns about new config sections
- [ ] `shipwright config validate` CLI command works (exits 0/1 appropriately)
- [ ] `docs/migration-guide-fallback-config.md` documents all new config keys
- [ ] `sw-config-validate-test.sh` has tests for new sections and migration function

## Notes
- Generated from pipeline plan at 2026-04-04T10:50:29Z
- Pipeline will update status as tasks complete
