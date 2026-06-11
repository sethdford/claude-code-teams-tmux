# Tasks — Cross-Repo Pattern Learning Engine for Fleet Mode

## Status: In Progress
Pipeline: standard | Branch: arch/cross-repo-pattern-learning-engine-for-f-626

## Checklist
- [ ] Task 1: Create `scripts/lib/fleet-memory.sh` with VERSION, store paths, defensive sourcing.
- [ ] Task 2: Implement `_fleet_init_store` + corruption quarantine (atomic writes).
- [ ] Task 3: Implement `_fleet_opt_in` privacy gate (default opt-in=false, per-repo override). *(blocks Task 7, 8)*
- [ ] Task 4: Implement `fleet_pattern_fingerprint` reusing `repo_hash`/`patterns.json`.
- [ ] Task 5: Implement `_fleet_score` + `fleet_pattern_match` with config-driven weights/threshold. *(blocks Task 8, 11-stats)*
- [ ] Task 6: Implement `fleet_pattern_capture` with `flock`, 500-cap, `emit_event`. *(depends on 3,4)*
- [ ] Task 7: Implement `fleet_pattern_inject` + `fleet_pattern_record_outcome` + `fleet_pattern_prune`. *(depends on 5)*
- [ ] Task 8: Add `patterns` sub-router (`list`/`show`/`apply`/`stats`/`prune`) to `sw-fleet.sh`. *(depends on 6,7)*
- [ ] Task 9: Add guarded capture hooks in `daemon-dispatch.sh` + `pipeline-commands.sh`. *(depends on 6)*
- [ ] Task 10: Add guarded injection hook in `loop-iteration.sh`. *(depends on 7)*
- [ ] Task 11: Extend `fleet_init` + config docs with `pattern_learning` / `fleet_pattern_matching` blocks.
- [ ] Task 12: Write `sw-fleet-patterns-test.sh` covering capture/store/retrieval/scoring/application/opt-out/concurrency. *(depends on 8)*
- [ ] Task 13: Register test in `package.json`; ensure `npm test` green.
- [ ] Task 14: Update `.claude/CLAUDE.md`, bump VERSIONs, sync AUTO docs.
- [ ] Task 15: Verify `shipwright fleet patterns list` is discoverable end-to-end (CLI router → sw-fleet → lib).
- [ ] `~/.shipwright/fleet-memory/{index.json,metrics.json}` created and maintained with the documented schema.
- [ ] Successful pipeline in one repo captures a pattern (fix + error→solution + test strategy); verified by test and `emit_event`.
- [ ] A new pipeline in a *similar* repo receives injected fleet patterns in its build prompt (cross-repo path proven by E2E test).
- [ ] Similarity scoring uses language/framework + error type + keywords with config-driven weights/threshold; boundary cases tested.
- [ ] `shipwright fleet patterns list|show|apply|stats|prune` all work and are reachable via the CLI router.

## Notes
- Generated from pipeline plan at 2026-06-11T13:43:15Z
- Pipeline will update status as tasks complete
