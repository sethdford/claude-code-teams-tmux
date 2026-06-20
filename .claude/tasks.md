# Tasks — Semantic Issue Clustering Engine for Pattern Reuse Across Pipelines

## Status: In Progress
Pipeline: standard | Branch: feat/semantic-issue-clustering-engine-for-pat-672

## Checklist
- [ ] Task 1: Run clustering suite; confirm 23/23 green (baseline before changes).
- [ ] Task 2: Compute baseline vs. clustered-recommendation success rates from events.
- [ ] Task 3: Add `success_rate_improvement` to metrics JSON (`jq -n --argjson`, `null`-safe).
- [ ] Task 4: Add metrics-field test (null-case + known-delta fixture).
- [ ] Task 5: Seed documented `clustering` block into `sw-init.sh` config template (absent-only).
- [ ] Task 6: (Optional) Add clustering health check to `sw-doctor.sh`.
- [ ] Task 7: Update CLAUDE.md metrics row for parity.
- [ ] Task 8: Run clustering + `sw-lib-daemon-poll-test.sh`; confirm no regressions.
- [ ] Task 9: Manual smoke — `shipwright clustering metrics | jq .` shows the new field.
- [ ] Task 10: Confirm VERSION == package.json (`3.3.0`); verify config discoverable via init.
- [ ] Existing 23 clustering tests + new metrics assertion pass.
- [ ] `metrics` emits `success_rate_improvement` (numeric or `null`, never fabricated).
- [ ] `daemon-config.json` from `init` contains a documented `clustering` block.
- [ ] No regressions in `sw-lib-daemon-poll-test.sh`.
- [ ] CLAUDE.md metrics description matches actual output.
- [ ] VERSION == package.json (`3.3.0`).
- [ ] All 5 acceptance criteria demonstrably satisfied (mapping below).

## Notes
- Generated from pipeline plan at 2026-06-20T01:35:42Z
- Pipeline will update status as tasks complete
