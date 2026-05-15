# Tasks — Pipeline Git State Validator and Auto-Cleanup Between Stages

## Status: In Progress
Pipeline: standard | Branch: ci/pipeline-git-state-validator-and-auto-cl-478

## Checklist
- [ ] Task 1: Draft `stage-manifests.json` with all 14 stages and policies.
- [ ] Task 2: Implement `scripts/lib/git-state-validator.sh` with
- [ ] Task 3: Implement `_auto_stash_dirty` and `_format_recovery_hint`.
- [ ] Task 4: Wire validator into
- [ ] Task 5: Add `SW_DISABLE_GIT_VALIDATOR` and `LOCAL_MODE` escape
- [ ] Task 6: Write `sw-git-state-validator-test.sh` with 8 test cases.
- [ ] Task 7: Add integration test that runs `run_stage_with_retry` with
- [ ] Task 8: Register new test in `package.json`.
- [ ] Task 9: Update `.claude/CLAUDE.md` (Shared Libraries table + new
- [ ] Task 10: Run full test suite (`npm test`) and confirm no
- [ ] `scripts/lib/git-state-validator.sh` exists and is sourced by the
- [ ] `.claude/pipeline-artifacts/stage-manifests.json` declares all 14
- [ ] `validate_before_stage` and `validate_after_stage` are called once
- [ ] Dirty-state abort emits an actionable recovery hint with a
- [ ] `npm test` is green including the new
- [ ] `shipwright docs check` reports no stale AUTO sections.
- [ ] Bash 3.2 compatibility verified (no `declare -A`, no `readarray`,

## Notes
- Generated from pipeline plan at 2026-05-15T01:25:47Z
- Pipeline will update status as tasks complete
