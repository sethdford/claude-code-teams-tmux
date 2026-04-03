# Pipeline Tasks — Build Loop Incremental State Checkpointing with Fine-Grained Recovery

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/loop-checkpoint.sh` with sub-iteration checkpoint functions (save, find_latest, restore, clean, step_name/step_num)
- [ ] Task 2: Extend `scripts/sw-checkpoint.sh` with `--step` flag on save, `list-steps` subcommand, and `clean-old` subcommand
- [ ] Task 3: Add 5 checkpoint save calls to `scripts/sw-loop.sh` at step boundaries (post-claude, post-commit, post-test, post-audit, post-quality)
- [ ] Task 4: Add step-skip logic to `scripts/sw-loop.sh` for resuming mid-iteration
- [ ] Task 5: Enhance `scripts/lib/loop-restart.sh` resume_state() to detect and restore sub-iteration checkpoints
- [ ] Task 6: Add checkpoint info to restart briefing in `scripts/lib/session-restart.sh`
- [ ] Task 7: Add sub-iteration checkpoint context to `compose_prompt()` in `scripts/lib/loop-iteration.sh`
- [ ] Task 8: Preserve sub-iteration checkpoints during session restart archival in `scripts/sw-loop.sh`
- [ ] Task 9: Add cleanup call to prune old sub-iteration checkpoints after each iteration
- [ ] Task 10: Write integration test suite `scripts/sw-loop-checkpoint-test.sh` with 11 test cases
- [ ] Task 11: Register test suite in `package.json` scripts section
- [ ] Task 12: Run full test suite to verify no regressions
- [ ] Sub-iteration checkpoints are saved after each of the 5 step boundaries within a loop iteration
- [ ] On resume/restart, the loop restores from the latest sub-iteration checkpoint and skips already-completed steps
- [ ] Restart briefing includes "Restored from checkpoint at iteration N, step M"
- [ ] Old checkpoints are cleaned up (keep last 3 iterations by default)
- [ ] Checkpoint write overhead is <100ms (measured in test)
- [ ] All 11 new test cases pass
- [ ] Existing test suites (`sw-loop-test.sh`, `sw-checkpoint-test.sh`, `sw-session-restart-test.sh`) still pass
- [ ] No regressions in `npm test` full suite

## Context
- Pipeline: standard
- Branch: feat/build-loop-incremental-state-checkpointi-337
- Issue: #337
- Generated: 2026-04-03T18:38:59Z
