# Tasks — Build Loop Per-Iteration Adaptive Model Selection with Auto-Escalation

## Status: In Progress
Pipeline: standard | Branch: feat/build-loop-per-iteration-adaptive-model-274

## Checklist
- [ ] Task 1: Create `scripts/lib/loop-model-selection.sh` with `loop_model_init`, `loop_model_for_position`, `loop_model_detect_stuck`, `loop_model_select`, `loop_model_track_cost`, `loop_model_summary`
- [ ] Task 2: Source `loop-model-selection.sh` in `sw-loop.sh` (line ~56)
- [ ] Task 3: Call `loop_model_init()` in `run_single_agent_loop()` initialization
- [ ] Task 4: Call `loop_model_select()` before `run_claude_iteration()` in the main loop, update `MODEL`
- [ ] Task 5: Call `loop_model_track_cost()` inside `accumulate_loop_tokens()`
- [ ] Task 6: Call `loop_model_summary()` in `show_summary()`
- [ ] Task 7: Add `loop.model_strategy` config to `.claude/daemon-config.json`
- [ ] Task 8: Add 12 new tests (21-32) to `sw-adaptive-model-test.sh`
- [ ] Task 9: Run existing test suite (`sw-adaptive-model-test.sh`) to verify no regressions
- [ ] Task 10: Run full `npm test` to verify no broader regressions

## Notes
- Generated from pipeline plan at 2026-03-15T01:04:47Z
- Pipeline will update status as tasks complete
