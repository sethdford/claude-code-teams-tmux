# Pipeline Tasks — Pipeline Failure Debug Artifact Auto-Collector

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/debug-collector.sh` with `collect_debug_bundle()`, `rotate_debug_bundles()`, `list_debug_bundles()`, `show_debug_bundle()`, `export_debug_bundle()`
- [ ] Task 2: Create `scripts/sw-debug-bundle.sh` CLI command with `list`, `show`, `export`, `clean`, `last` subcommands (depends on Task 1)
- [ ] Task 3: Modify `scripts/lib/pipeline-state.sh` — call `collect_debug_bundle()` from `mark_stage_failed()` and include bundle path in GitHub failure comment (depends on Task 1)
- [ ] Task 4: Modify `scripts/lib/pipeline-execution.sh` — reference debug bundle in retry context file (depends on Task 1)
- [ ] Task 5: Register `debug-bundle` subcommand in `scripts/sw` CLI router (depends on Task 2)
- [ ] Task 6: Register `debug.bundle_created` event type in `config/event-schema.json`
- [ ] Task 7: Create `scripts/sw-debug-bundle-test.sh` test suite with 12 test cases (depends on Tasks 1-6)
- [ ] Task 8: Register test suite in `package.json` (depends on Task 7)
- [ ] Task 9: Run test suite and fix any failures
- [ ] Task 10: Run existing pipeline tests to verify no regressions
- [ ] `collect_debug_bundle()` creates a complete bundle on every stage failure
- [ ] Bundle contains: stage log, error classification, environment (secrets filtered), git state, pipeline state, recent events, error log tail, manifest
- [ ] Bundles are auto-rotated (max 10 by default)
- [ ] GitHub failure comment includes bundle path
- [ ] Retry context file includes bundle contents for agent consumption
- [ ] `shipwright debug-bundle list|show|export|clean|last` CLI works
- [ ] `debug.bundle_created` event emitted and schema-registered
- [ ] Test suite passes with 12+ test cases
- [ ] Existing pipeline tests pass (no regressions)
- [ ] All scripts use `set -euo pipefail`, Bash 3.2 compatible, VERSION synced

## Context
- Pipeline: autonomous
- Branch: ci/issue-278
- Issue: none
- Generated: 2026-03-15T07:55:47Z
