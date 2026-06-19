# Tasks — Real-Time Pipeline Progress Stream with Stage-Level Transparency

## Status: In Progress
Pipeline: standard | Branch: feat/real-time-pipeline-progress-stream-with-659

## Checklist
- [ ] Task 1: Scaffold `scripts/lib/pipeline-watch.sh` (VERSION, source guard, stubs).
- [ ] Task 2: Implement `_watch_read_state_field` (snapshot-safe frontmatter parse). *(blocks 8)*
- [ ] Task 3: Implement `_watch_render_stage_bar` (progress bar + per-stage glyphs). *(blocks 8)*
- [ ] Task 4: Implement `_watch_elapsed` (live elapsed, portable date fallback). *(blocks 8)*
- [ ] Task 5: Implement `_watch_build_panel` (iteration/test/commits/tokens, jq-guarded). *(blocks 8)*
- [ ] Task 6: Implement `_watch_activity` (events.jsonl tail, formatted). *(blocks 8)*
- [ ] Task 7: Implement `_watch_estimate_completion` (advisory ETA).
- [ ] Task 8: Implement `pipeline_watch` main loop + clean exit + stall guard + signal traps. *(needs 2–6)*
- [ ] Task 9: Add `watch)` dispatch + source new lib in `sw-pipeline.sh`. *(needs 8)*
- [ ] Task 10: Add `watch` help example in `pipeline-cli.sh`.
- [ ] Task 11: Write `sw-pipeline-watch-test.sh` (≥12 assertions).
- [ ] Task 12: Register test in `package.json` `test` script.
- [ ] Task 13: Update `.claude/CLAUDE.md` command table; run `docs sync`.
- [ ] Task 14: (Optional) WebSocket capability-gated fast-path.
- [ ] Task 15: Run full suite + `shipwright version check`; verify no regressions.
- [ ] `shipwright pipeline watch <issue>` streams live progress, refreshing every ~5s.
- [ ] Shows: current stage name, progress bar, elapsed time, last-activity timestamp.
- [ ] Build stage adds: iteration count, test pass/fail status, recent commits, token usage.
- [ ] Exits cleanly (code 0 + summary) on `complete`/`failed`/`aborted`; Ctrl-C exits 0.
- [ ] Works for daemon-spawned and manual pipelines (verified against `.claude/pipeline-state.md`).

## Notes
- Generated from pipeline plan at 2026-06-19T01:31:40Z
- Pipeline will update status as tasks complete
