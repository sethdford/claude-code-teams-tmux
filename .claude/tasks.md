# Tasks — Fleet-Wide Pattern Mining & Knowledge Transfer Engine

## Status: In Progress
Pipeline: standard | Branch: feat/fleet-wide-pattern-mining-knowledge-tran-668

## Checklist
- [ ] Task 1: Bump `VERSION` in `sw-knowledge.sh` + `package.json` (blocks nothing).
- [ ] Task 2: Add `FLEET_PATTERNS_FILE` storage + `ensure_patterns_file()`.
- [ ] Task 3: Implement `_km_extract_success` jq extractor. *(blocks Task 4)*
- [ ] Task 4: Extend `cmd_mine` to consolidate success patterns → `fleet-patterns.json`. *(blocked by 3)*
- [ ] Task 5: Implement `cmd_recommend` with similarity scoring + threshold + `--json`. *(blocked by 4)*
- [ ] Task 6: Add reuse/recommendation/success-rate metrics to `cmd_report`/`cmd_show`.
- [ ] Task 7: Add `recommend)` to the case dispatch.
- [ ] Task 8: Implement `composer_consult_knowledge()` in `sw-pipeline-composer.sh` (read-only, fail-safe). *(blocked by 5)*
- [ ] Task 9: Wire `total_reuses` bump when composer applies a recommendation. *(blocked by 8)*
- [ ] Task 10: Add unit tests: success extraction, recommend scoring boundaries (59/60/61), empty DB, metrics math.
- [ ] Task 11: Add mocked composer-integration test (recommend returns → composed-pipeline annotated; recommend fails → composition unchanged).
- [ ] Task 12: Update `.claude/CLAUDE.md` AUTO sections + `shipwright docs sync`; verify `shipwright knowledge recommend` is discoverable.
- [ ] Task 13: Run `./scripts/sw-knowledge-test.sh` + `shipwright version check` + `shipwright doctor`.
- [ ] `knowledge mine` extracts successful pipeline approaches and writes `~/.shipwright/fleet-patterns.json` with success-rate, complexity, cost metadata.
- [ ] `knowledge recommend --issue "<t>"` returns a ranked successful approach by similarity, with confidence score.
- [ ] Composer consults the pattern library before composing; recommendation acts as a prior, never overriding explicit config, and never aborts composition on error.
- [ ] Reuse rate and success-rate metrics tracked and shown in `knowledge report`.
- [ ] All new + existing `sw-knowledge` and composer tests pass; `version check` and `doctor` clean.
- [ ] Docs (AUTO sections) regenerated; new command discoverable via CLI.

## Notes
- Generated from pipeline plan at 2026-06-19T19:05:33Z
- Pipeline will update status as tasks complete
