# Tasks — Fallback Policy Migrator — Convert 67 Static Fallbacks to Config-Driven Adaptive Overrides

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-620

## Checklist
- [ ] Task 1: Inventory + filter to the canonical 67 high-impact sites; reconcile vs. existing 20
- [ ] Task 2: Define var→key namespace map (one key per semantic fallback)
- [ ] Task 3: Expand `config/fallback-policy.json` to ~67 entries (`static == literal`)
- [ ] Task 4: `fallback validate` + `jq empty` green on expanded config
- [ ] Task 5: Migrate `loop.*` call-sites + `sw-loop-test.sh`
- [ ] Task 6: Migrate `pipeline.*` call-sites + pipeline lib tests
- [ ] Task 7: Migrate `daemon.*`/`patrol.*` call-sites + `sw-daemon-test.sh`
- [ ] Task 8: Migrate `stall.*`/`recovery.*` call-sites + tests
- [ ] Task 9: Migrate `network.*` call-sites
- [ ] Task 10: Migrate `review.*`/`simulation.*`/`cleanup.*` call-sites
- [ ] Task 11: Extend `sw-fallback-policy-test.sh` (count, range, fail-safe, behavior-preservation)
- [ ] Task 12: Update `.claude/CLAUDE.md`; run `fallback audit`
- [ ] Task 13: Full `npm test` green
- [ ] Task 14: `VERSION` header bumps + `shipwright version check`
- [ ] `config/fallback-policy.json` declares **≥ 67** policies; `shipwright fallback validate` exits 0.
- [ ] **≥ 67** production call-sites resolve through `_smart_fallback` (verified by `grep -c`, excluding the CLI self-reference).
- [ ] Every migrated `static` equals its original call-site literal (behavior-preservation tests pass).
- [ ] `shipwright fallback audit scripts` reports `declared ≥ 67`.
- [ ] Deleting `config/fallback-policy.json` restores pre-migration behavior (fail-safe test passes).
- [ ] `sw-fallback-policy-test.sh` extended and green; full `npm test` green.

## Notes
- Generated from pipeline plan at 2026-06-10T20:59:36Z
- Pipeline will update status as tasks complete
