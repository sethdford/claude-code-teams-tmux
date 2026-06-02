# Tasks — Flaky Test Detection & Auto-Quarantine System

## Status: In Progress
Pipeline: standard | Branch: test/flaky-test-detection-auto-quarantine-sys-566

## Checklist
- [ ] Task 1: Bump `SCHEMA_VERSION` to 7; add `test_results` + `flaky_quarantine` tables and indexes to `init_schema`.
- [ ] Task 2: Add v6→v7 migration block (idempotent, reversible-by-recreate) to `db_migrate`.
- [ ] Task 3: Add `db_record_test_result`, `db_query_test_history`, `db_flaky_candidates`, `db_record_quarantine`, `db_list_quarantined` helpers.
- [ ] Task 4: Implement `scripts/lib/flaky-detection.sh` parser adapters (vitest/jest + TAP) and `flaky_record_results` (transactional, guarded).
- [ ] Task 5: Implement `flaky_detect` (variance over last N runs, `--json`) with `emit_event`.
- [ ] Task 6: Implement `flaky_quarantine_test` with framework detection, reversible marker, atomic write, safe-skip on ambiguity.
- [ ] Task 7: Implement `flaky_create_issue` (NO_GITHUB-guarded, de-duped, capped, pattern-data body).
- [ ] Task 8: Create `scripts/sw-flaky.sh` CLI; register `flaky` in `scripts/sw`.
- [ ] Task 9: Add `patrol_flaky_tests` weekly-gated check to `daemon-patrol.sh` and register it in the run/summary sequence.
- [ ] Task 10: Read flaky/patrol config in `sw-daemon.sh`; add defaults to `daemon init` config.
- [ ] Task 11: Wire `flaky_record_results` into `loop-iteration.sh` after the test run (guarded).
- [ ] Task 12: Add `quarantinedTests` query to `dashboard/server.ts` and an accessible widget to `dashboard/public/`.
- [ ] Task 13: Write `scripts/sw-flaky-test.sh`; add it to `package.json` test list.
- [ ] Task 14: Update `.claude/CLAUDE.md` + run `docs sync`; ensure VERSION strings match package.json.
- [ ] `test_results` + `flaky_quarantine` tables exist; `db_migrate` moves v6→v7 idempotently (verified by double-run test).
- [ ] `shipwright flaky detect` reports tests with ≥20% fail rate over the last 10 runs.
- [ ] `shipwright flaky quarantine --auto` adds a reversible `.skip`/marker annotation only when the test line is unambiguous; otherwise records + files an issue.
- [ ] A `flaky-test`-labeled GitHub issue with a failure-pattern table is created (de-duped, NO_GITHUB-guarded).
- [ ] Dashboard shows the quarantined-test count and links to issues.
- [ ] `daemon patrol` runs flaky detection on a weekly gate and is registered in the run sequence.

## Notes
- Generated from pipeline plan at 2026-06-02T01:40:13Z
- Pipeline will update status as tasks complete
