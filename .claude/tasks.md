# Tasks — Intelligent Stage Skipping Engine Based on Change Impact Analysis

## Status: In Progress
Pipeline: standard | Branch: feat/intelligent-stage-skipping-engine-based-400

## Checklist
- [ ] T1: Create `change-impact.sh` (VERSION, source guard, defaults here-doc, bash 3.2).
- [ ] T2: `classify_change_impact()` — `git diff --name-only $BASE_BRANCH...HEAD`, regex bucket, atomic write of `change-impact.json`.
- [ ] T3: `change_impact_should_skip()` — `SW_NO_SKIP` + `never_skip` guards; defensive refusal when `counts.code>0`.
- [ ] T4: Wire first call in `pipeline_should_skip_stage`; fall through to existing label/complexity logic.
- [ ] T5: Emit `stage_skipped` event + append `skip-log.jsonl` in `pipeline-execution.sh`.
- [ ] T6: Render "Skipped Stages" in `pipeline-state.md`.
- [ ] T7: Extend vitals report with skip summary and category counts.
- [ ] T8: Seed default `stage_skip_rules` in `sw-prep.sh`.
- [ ] T9: Write `sw-change-impact-test.sh` (10 scenarios below).
- [ ] T10: Register test in `package.json`.
- [ ] T11: Update `.claude/CLAUDE.md` (feature flags + runtime state).
- [ ] T12: Run `npm test`; fix regressions.

## Notes
- Generated from pipeline plan at 2026-04-17T18:46:43Z
- Pipeline will update status as tasks complete
