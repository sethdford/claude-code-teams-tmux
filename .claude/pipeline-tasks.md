# Pipeline Tasks — Build Loop Failure Mode Classification and Adaptive Recovery

## Implementation Checklist
- [ ] Create `scripts/lib/loop-failure-modes.sh` with module guard
- [ ] Implement `classify_loop_failure_mode()` dispatcher
- [ ] Implement `_detect_context_exhaustion()` heuristic
- [ ] Implement `_detect_infinite_loop()` heuristic
- [ ] Implement `_detect_test_flakiness()` heuristic
- [ ] Implement `_detect_dependency_issue()` heuristic
- [ ] Implement `get_recovery_strategy()` function
- [ ] Implement `apply_recovery_context_exhaustion()`
- [ ] Implement `apply_recovery_infinite_loop()`
- [ ] Implement `apply_recovery_test_flakiness()`
- [ ] Implement `apply_recovery_dependency_issue()`
- [ ] Implement `apply_recovery_code_error()`
- [ ] Update sw-loop.sh: source new module at top
- [ ] Add failure classification call in `run_loop_with_restarts()` at failure point
- [ ] Add `--failure-mode` flag to sw-loop.sh argument parser
- [ ] Emit event: `loop.failure_mode_classified` with mode, confidence, evidence
- [ ] Call recovery strategy before session restart
- [ ] Emit event: `loop.recovery_strategy_applied` with strategy, actions
- [ ] Update `loop-restart.sh` to accept failure_mode in restart briefing
- [ ] Inject mode-specific guidance into restart briefing

## Context
- Pipeline: standard
- Branch: feat/build-loop-failure-mode-classification-a-246
- Issue: #246
- Generated: 2026-03-10T12:33:19Z
