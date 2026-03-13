# Tasks — Platform Capability Self-Assessment Registry with Proven Pattern Boundaries

## Status: In Progress
Pipeline: standard | Branch: arch/platform-capability-self-assessment-regi-256

## Checklist
- [ ] Task 1: Add `capability_registry` table + schema v7 migration + DB CRUD functions to `sw-db.sh`
- [ ] Task 2: Create `scripts/lib/capability-registry.sh` with core logic (check, record, conservative mode)
- [ ] Task 3: Add `--override-capability-check` flag to `scripts/lib/pipeline-cli.sh`
- [ ] Task 4: Integrate capability pre-flight check into `scripts/lib/pipeline-util.sh` `preflight_checks()`
- [ ] Task 5: Integrate capability pre-flight check into `scripts/lib/daemon-state.sh` `preflight_checks()`
- [ ] Task 6: Record capability outcomes in `scripts/lib/pipeline-commands.sh` (success + failure paths)
- [ ] Task 7: Create `scripts/sw-capability.sh` CLI command (show, heatmap, reset, configure, status)
- [ ] Task 8: Register `capability` subcommand in `scripts/sw` CLI router
- [ ] Task 9: Add `GET /api/capabilities` endpoint to `dashboard/server.ts`
- [ ] Task 10: Create `scripts/sw-capability-test.sh` test suite with mock registry
- [ ] Task 11: Register test in `package.json`
- [ ] Task 12: Run test suite and fix any failures
- [ ] `capability_registry` table exists in SQLite schema v7
- [ ] `sw capability show` displays registry entries with success rates
- [ ] `sw capability heatmap` shows terminal-colored category heatmap
- [ ] Pre-flight check rejects tasks with <50% success rate (when >=5 samples)
- [ ] Pre-flight check passes when registry is empty (cold start)
- [ ] Pre-flight check passes when `--override-capability-check` is used
- [ ] Pipeline completion auto-updates registry (both success and failure)
- [ ] Conservative mode activates when overall success rate <70%

## Notes
- Generated from pipeline plan at 2026-03-13T15:13:58Z
- Pipeline will update status as tasks complete
