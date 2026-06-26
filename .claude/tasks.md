# Tasks — Pipeline State Corruption Auto-Recovery with Atomic Writes

## Status: In Progress
Pipeline: standard | Branch: ci/pipeline-state-corruption-auto-recovery-697

## Checklist
- [ ] Task 1: Add `atomic_write_file()` (tmp-source + flock + optional validator) to `helpers.sh`
- [ ] Task 2: Add `validate_state_file()` to `pipeline-state.sh`
- [ ] Task 3: Rewrite `write_state()` to be atomic with `.bak` last-known-good rotation
- [ ] Task 4: Add `recover_state_from_checkpoint()` reconstructing minimal valid state
- [ ] Task 5: Add `recover_state()` rollback ladder with `emit_event` instrumentation
- [ ] Task 6: Validate + recover at the top of `resume_state()`
- [ ] Task 7: Add unit tests for atomic write (no stray tmp, always-valid file)
- [ ] Task 8: Add unit tests for `validate_state_file` (good / truncated / missing-goal / empty)
- [ ] Task 9: Add unit tests for `.bak` rollback
- [ ] Task 10: Add unit tests for checkpoint rollback
- [ ] Task 11: Add concurrent-write safety test (10 parallel writers)
- [ ] Task 12: Add end-to-end corruption-recovery case to `sw-auto-recovery-test.sh`
- [ ] Task 13: Add `atomic_write_file()` tests to `sw-lib-helpers-test.sh`
- [ ] Task 14: Bump `VERSION` in edited scripts; run `shipwright version check`
- [ ] Task 15: Run targeted suites + `npm test`; fix regressions
- [ ] `write_state()` never writes the live file directly — always tmp → validate → `flock`+`mv` (grep shows no direct `> "$STATE_FILE"` / `>> "$STATE_FILE"` writes remain).
- [ ] `validate_state_file()` rejects truncated, empty, and missing-`goal:` files; accepts well-formed ones.
- [ ] Corrupted `STATE_FILE` auto-recovers from `${STATE_FILE}.bak`, and from the latest checkpoint when no `.bak` exists; `resume_state()` continues from the recovered stage instead of `exit 1`.
- [ ] Concurrent writes are serialized via `flock`; 10-writer parallel test leaves a valid file and no stray `*.tmp.*`.
- [ ] New unit + integration tests pass; `npm test` is green.

## Notes
- Generated from pipeline plan at 2026-06-26T01:33:15Z
- Pipeline will update status as tasks complete
