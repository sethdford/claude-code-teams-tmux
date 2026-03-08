# Tasks — Installation and Setup Telemetry with Automatic Recovery Checkpoint System

## Status: In Progress
Pipeline: standard | Branch: feat/installation-and-setup-telemetry-with-au-210

## Checklist
- [ ] Task 1: Create `scripts/lib/setup-telemetry.sh` with checkpoint read/write and step tracking helpers
- [ ] Task 2: Add `--resume` flag parsing to `scripts/sw-init.sh` and source setup-telemetry.sh
- [ ] Task 3: Instrument all 14 steps in `scripts/sw-init.sh` with `setup_step_start/end/fail`
- [ ] Task 4: Instrument `scripts/sw-setup.sh` phases with telemetry and `--resume` passthrough
- [ ] Task 5: Instrument `install.sh` prereq checks with telemetry
- [ ] Task 6: Add section 9 "SETUP STATUS" to `scripts/sw-doctor.sh`
- [ ] Task 7: Update `config/event-schema.json` with setup.* event types
- [ ] Task 8: Create `scripts/sw-setup-telemetry-test.sh` test suite
- [ ] Task 9: Register test suite in `package.json`
- [ ] Task 10: Run full test suite, fix any failures
- [ ] `scripts/lib/setup-telemetry.sh` exists with all documented functions
- [ ] Running `shipwright setup` creates `~/.shipwright/setup-checkpoint.json`
- [ ] Each setup step emits `setup.step` event to `events.jsonl` with step name, duration, and status
- [ ] `shipwright setup --resume` skips completed steps and resumes from last failure
- [ ] `shipwright doctor` reports incomplete setup with `--resume` suggestion
- [ ] `config/event-schema.json` includes `setup.started`, `setup.step`, `setup.completed`, `setup.resumed`
- [ ] Test suite passes: `./scripts/sw-setup-telemetry-test.sh`
- [ ] `npm test` passes (no regressions)
- [ ] Checkpoint file expires after 24h (stale checkpoints don't block fresh installs)
- [ ] `--repair` flag ignores existing checkpoint (forces clean start)

## Notes
- Generated from pipeline plan at 2026-03-08T00:47:36Z
- Pipeline will update status as tasks complete
