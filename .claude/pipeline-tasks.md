# Pipeline Tasks — Real-Time Context Window Health Monitor for Build Loop Exhaustion Prevention

## Implementation Checklist
- [ ] Task 1: Add `context_budget_threshold()` config reader and refactor `_check` to use it
- [ ] Task 2: Create `scripts/lib/context-health.sh` orchestrator (tick/act/snapshot/alert)
- [ ] Task 3: Emit `context_health` events via existing `emit_event` on each tick
- [ ] Task 4: Wire `context_health_tick` into `sw-loop.sh` iteration boundary
- [ ] Task 5: Wire auto-trim path (red → `context_budget_trim`) into loop
- [ ] Task 6: Escalate critical → existing restart flag with `context_exhaustion` cause
- [ ] Task 7: Add `context_health_panel` to `sw-pipeline-vitals.sh`
- [ ] Task 8: Create `sw-context-health-test.sh` with 10+ test cases
- [ ] Task 9: Register test suite in `package.json`
- [ ] Task 10: Add `loop.context_alert_threshold` etc. to daemon-config defaults
- [ ] Task 11: Update `.claude/CLAUDE.md` library AUTO section
- [ ] Task 12: Verify `npm test` passes with no regressions
- [ ] Per-iteration context estimate computed and snapshot written
- [ ] Threshold configurable via `daemon-config.json` (default 80%)
- [ ] Transition events emitted to events.jsonl with `type=context_health`
- [ ] Red status triggers `context_budget_trim` on prompt before claude invocation
- [ ] Critical status triggers existing session restart with `context_exhaustion` cause
- [ ] `shipwright vitals` output shows a context health panel
- [ ] New test suite passes; `npm test` green; no regressions in loop/vitals/context-budget tests
- [ ] Feature degrades gracefully if `context-budget.sh` or jq is unavailable

## Context
- Pipeline: standard
- Branch: feat/real-time-context-window-health-monitor-399
- Issue: #399
- Generated: 2026-04-17T12:47:29Z
