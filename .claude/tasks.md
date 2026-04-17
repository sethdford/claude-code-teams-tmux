# Tasks — Setup and First-Run Analytics Engine with Drop-off Tracking

## Status: In Progress
Pipeline: standard | Branch: feat/setup-and-first-run-analytics-engine-wit-404

## Checklist
- [ ] **Task 1**: Create `scripts/lib/analytics.sh` with `emit_analytics_event()`, atomic write, validation
- [ ] **Task 2**: Create `scripts/lib/analytics-schema.json` with allowed fields and forbidden patterns
- [ ] **Task 3**: Create `scripts/sw-analytics.sh` with `emit`, `report`, `clear` subcommands
- [ ] **Task 4**: Implement funnel analysis and report generation in `sw-analytics.sh`
- [ ] **Task 5**: Modify `scripts/sw-setup.sh` to emit events at each phase (prerequisites, PATH, tmux, CLI)
- [ ] **Task 6**: Modify `scripts/sw-init.sh` to emit setup flow events
- [ ] **Task 7**: Modify `scripts/sw-pipeline.sh` to track pipeline start/stage completion/final outcome
- [ ] **Task 8**: Integrate pipeline stage tracking to emit `stage_reached` on failure
- [ ] **Task 9**: Implement PII filtering in `emit_analytics_event()` — validate against schema
- [ ] **Task 10**: Add log rotation logic to keep analytics.jsonl < 100MB
- [ ] **Task 11**: Create `scripts/sw-analytics-test.sh` with unit and integration tests
- [ ] **Task 12**: Update `scripts/sw` router to dispatch `analytics` subcommand
- [ ] **Task 13**: Add analytics test suite to `package.json`
- [ ] **Task 14**: Document analytics event types in `.claude/CLAUDE.md` under a new "Analytics Events" section
- [ ] **Task 15**: Verify privacy preservation — audit all emitted events for sensitive data

## Notes
- Generated from pipeline plan at 2026-04-17T18:42:03Z
- Pipeline will update status as tasks complete
