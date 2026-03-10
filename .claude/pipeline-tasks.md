# Pipeline Tasks — Build Loop Iteration Progress Metrics Dashboard Widget

## Implementation Checklist
- [ ] Task 1: Add `write_build_loop_status()` function to `scripts/lib/loop-progress.sh` with atomic JSON writes
- [ ] Task 2: Add `TEST_PASS_STREAK` counter to `sw-loop.sh` (increment on pass, reset on fail)
- [ ] Task 3: Call `write_build_loop_status` after `write_progress` in the main iteration loop (line ~2384)
- [ ] Task 4: Also call at loop start (initial state) and loop end (final state with status=completed/failed)
- [ ] Task 5: Add `loop_show_status()` function with formatted and `--json` output modes, trend indicators
- [ ] Task 6: Add `status` subcommand dispatch at top of argument parsing in `sw-loop.sh`
- [ ] Task 7: Update `readLogIterations()` in `dashboard/server.ts` to read `build_loop_status.json`
- [ ] Task 8: Add `GET /api/loop-status/:issue` endpoint to dashboard server
- [ ] Task 9: Add build loop metrics widget to pipeline card in `dashboard/src/views/overview.ts`
- [ ] Task 10: Add tests for `write_build_loop_status` and `loop_show_status` to `sw-loop-test.sh`
- [ ] `build_loop_status.json` written atomically after every iteration with all specified fields
- [ ] `shipwright loop status` displays formatted output with trend indicators
- [ ] `shipwright loop status --json` outputs valid, parseable JSON
- [ ] Dashboard pipeline card shows iteration progress, test status, files changed, context usage
- [ ] Dashboard auto-refreshes via existing WebSocket push (no polling needed — already pushes every 2s)
- [ ] All new code follows Bash 3.2 compat rules and project conventions
- [ ] Tests pass: `npm test` green
- [ ] Trend indicators: use existing pattern (consecutive_low_progress for degrading, test_pass_streak for improving)

## Context
- Pipeline: standard
- Branch: feat/build-loop-iteration-progress-metrics-da-247
- Issue: #247
- Generated: 2026-03-10T16:46:21Z
