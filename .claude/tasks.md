# Tasks — Smart Template Recommendation Engine — Auto-Select Optimal Pipeline Configuration

## Status: In Progress
Pipeline: standard | Branch: feat/smart-template-recommendation-engine-aut-624

## Checklist
- [ ] Task 1: Create `scripts/lib/template-recommender.sh` skeleton (VERSION, guarded sourcing, no side effects)
- [ ] Task 2: Implement offline-safe `_tr_repo_context` (file count, test ratio, language; `{}` when unavailable)
- [ ] Task 3: Implement `_tr_score_templates` — label/keyword/complexity/size/coverage/history signals (jq `--arg`)
- [ ] Task 4: Implement `recommend_template` — argmax + separation-based confidence + reasoning array (JSON out)
- [ ] Task 5: Implement `scripts/sw-template-recommender.sh` CLI (`recommend`, `explain`, `--json`, `help`, `--version`)
- [ ] Task 6: Implement feedback loop — `feedback`/`accuracy`, JSONL log + `bandit_select_template` arm updates
- [ ] Task 7: Refactor `daemon-triage.sh:select_pipeline_template` to delegate to `recommend_template`
- [ ] Task 8: Add `--auto-template` flag to `pipeline-cli.sh` + `sw-pipeline.sh` (resolve before template load)
- [ ] Task 9: Daemon auto-apply when confidence > 80%; log + `emit_event "template_recommendation"`
- [ ] Task 10: Write `sw-template-recommender-test.sh` (synthetic issues) + register in `package.json`
- [ ] Task 11: Add `template)` route in `scripts/sw` and entry in `show_help_all`
- [ ] Task 12: Document `shipwright template recommend` in `.claude/CLAUDE.md` hand-written tables
- [ ] Task 13: Run `shellcheck` + full `npm test`; fix regressions in daemon-triage/pipeline suites
- [ ] `shipwright template recommend --issue N` prints recommended template + confidence + reasoning; `--json` emits valid structured output.
- [ ] Scoring considers labels, description keywords, repo size, test coverage, and per-template historical success rate.
- [ ] Daemon (`auto_template=true`) logs the recommendation and auto-applies only when confidence > 80%, else falls back.
- [ ] Feedback loop records recommendations and reports recommended-vs-actual accuracy (`template … accuracy`).
- [ ] `pipeline start --auto-template` resolves and loads the recommended template when no explicit `--template` is given.
- [ ] `scripts/sw-template-recommender-test.sh` passes with synthetic issues and is registered in `package.json`.
- [ ] Works with `NO_GITHUB=true` (no `gh`/network calls); bash 3.2 compatible; `shellcheck` clean.

## Notes
- Generated from pipeline plan at 2026-06-11T13:43:57Z
- Pipeline will update status as tasks complete
