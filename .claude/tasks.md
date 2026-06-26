# Tasks — Pipeline Progress Estimation with Real-Time ETA and Completion Percentage

## Status: In Progress
Pipeline: standard | Branch: feat/pipeline-progress-estimation-with-real-t-692

## Checklist
- [x] Task 1: Persist `stage_timings:` block in `pipeline-state.sh::write_state()` *(blocks 4, 9)*
- [x] Task 2: Add `query_stage_durations()` + input validation to `sw-db.sh` *(blocks 4)*
- [ ] Task 3: Verify/ensure `record_stage()` fires on every stage end (build/test/delivery libs)
- [x] Task 4: Create `scripts/lib/pipeline-eta.sh` (percentile + estimate + 24h cache) *(needs 1,2)*
- [x] Task 5: Implement no-history fallback (`MIN_SAMPLES`, stage-count output)
- [x] Task 6: Wire `sw-status.sh` → `Progress: X% (~Y min remaining)` *(needs 4)*
- [ ] Task 7: Upgrade `server.ts` metrics to P50/P90 + attach progress/eta fields *(needs 3)*
- [ ] Task 8: Extend `dashboard/src/types/api.ts` interfaces
- [ ] Task 9: Render progress bar + ETA badge in `overview.ts` + `styles.css` *(needs 8)*
- [ ] Task 10: `emit_event "eta.computed"` for accuracy observability
- [x] Task 11: Write `sw-pipeline-eta-test.sh` (mock DB/cache) + bash/TS parity fixture
- [x] Task 12: Register test in `package.json`; run `npm test`
- [ ] Task 13: Update `.claude/CLAUDE.md`; bump `VERSION` in new/edited scripts
- [ ] `stage_timings` persisted to `pipeline-state.md`; durations land in `pipeline_stages`
- [ ] `query_stage_durations()` returns correct P50/P90 via `percentile()`
- [ ] `shipwright status` shows `Progress: X% (~Y min remaining)` for running pipelines
- [ ] No-history repos show `Progress: N/M stages` (no bogus ETA)
- [ ] Dashboard shows progress bar + ETA, updating ≤2s
- [ ] Estimates cached in intelligence cache with 24h TTL
- [ ] New test suite passes; `npm test` fully green; bash/TS formulas agree

## Notes
- Generated from pipeline plan at 2026-06-26T01:34:59Z
- Pipeline will update status as tasks complete
