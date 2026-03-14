# Pipeline Tasks — Build Loop Goal Achievement Verification Checkpoint System

## Implementation Checklist
- [ ] Checkpoint configuration helpers (`get_goal_check_config()`, `is_goal_check_enabled()`) added to sw-loop.sh
- [ ] Checkpoint injection function (`inject_goal_checkpoint()`) added
- [ ] Checkpoint prompt builder (`build_checkpoint_prompt()`) added
- [ ] Response parser (`parse_goal_checkpoint_response()`) added
- [ ] State variables (`GOAL_CHECK_ENABLED`, `GOAL_CHECK_INTERVAL`, `GOAL_REACHED`, `CHECKPOINT_TRIGGERED`) added
- [ ] Initialization function (`init_goal_checkpoint_system()`) called at script startup
- [ ] Main loop modified to: check for checkpoint, inject prompt, parse response
- [ ] LOOP_COMPLETE logic extended to handle GOAL_ACHIEVED signal
- [ ] CLI flags added: `--goal-check-interval N`
- [ ] daemon-config.json updated with `loop.goal_check_interval` schema (default: 3)
- [ ] Checkpoint injection at multiples of 3 (and custom intervals)
- [ ] Checkpoint skipped before iteration 2
- [ ] GOAL_ACHIEVED signal detection
- [ ] Early loop exit on goal achieved
- [ ] Configuration loading (defaults, overrides, invalid values)
- [ ] Prompt content verification (includes goal, context, signal instruction)
- [ ] All 10+ test cases in sw-loop-test.sh passing
- [ ] CLAUDE.md "Build Loop Capabilities" section updated
- [ ] Checkpoint feature described with example usage
- [ ] Configuration documented: `loop.goal_check_interval`, `SW_GOAL_CHECK_INTERVAL` env var

## Context
- Pipeline: standard
- Branch: arch/build-loop-goal-achievement-verification-268
- Issue: #268
- Generated: 2026-03-14T18:22:47Z
