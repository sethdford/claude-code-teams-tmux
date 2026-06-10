# Tasks — Error Feedback Loop Quality Analyzer — Measure Actionability & Agent Comprehension

## Status: In Progress
Pipeline: standard | Branch: feat/error-feedback-loop-quality-analyzer-mea-618

## Checklist
- [ ] Task 1: Create `scripts/lib/error-quality-analyzer.sh` skeleton (guard, VERSION, reused-fn fallbacks). *(blocks 2–7)*
- [ ] Task 2: Implement `eqa_score_summary_file` — reads error-summary.json, per-line score+classify, jq-built JSON (**AC1**). *(blocks 3,11)*
- [ ] Task 3: Implement `eqa_emit_iteration_quality` — emits `error.quality` event (**AC4**). *(blocked by 2; blocks 9)*
- [ ] Task 4: Implement `eqa_correlate` over events.jsonl with robust parse + min_sample (**AC2**). *(blocked by 3-shape; blocks 5)*
- [ ] Task 5: Implement `eqa_top_offenders` — bottom-5 ascending (**AC5**). *(blocked by 4; blocks 6)*
- [ ] Task 6: Implement `eqa_generate_templates` — atomic write `.claude/error-templates.json` (**AC3**). *(blocked by 5; blocks 10)*
- [ ] Task 7: Implement `eqa_report` orchestrator (human table + templates).
- [ ] Task 8: Create `scripts/sw-error-quality.sh` CLI + `errors)` dispatch in `scripts/sw`.
- [ ] Task 9: Wire `eqa_emit_iteration_quality` into `sw-loop.sh` (**AC1+AC4**, guarded). *(blocked by 3)*
- [ ] Task 10: Wire template injection into `loop-iteration.sh`. *(blocked by 6)*
- [ ] Task 11: Write `scripts/sw-lib-error-quality-analyzer-test.sh`. *(blocked by 2–7)*
- [ ] Task 12: Register test in `package.json`.
- [ ] Task 13: Run new + regression tests; fix failures.
- [ ] Task 14: Sync VERSION + update AUTO docs tables.
- [ ] `eqa_score_summary_file` scores every `error_lines[]` entry of a real `error-summary.json` (specificity, file:line, type) — **AC1**.
- [ ] `error.quality` events appear in `events.jsonl` once per failing iteration with numeric scores — **AC4**.
- [ ] `eqa_correlate` produces per-type `fix_rate` tied to next-iteration outcome — **AC2**.
- [ ] `eqa_top_offenders` lists the 5 lowest-actionability types (min_sample-gated) — **AC5**.
- [ ] `eqa_generate_templates` writes `.claude/error-templates.json`; templates inject into the next build prompt — **AC3**.
- [ ] New test suite passes; `sw-loop-test.sh` + `sw-lib-error-actionability-test.sh` still pass; test registered in `package.json`.

## Notes
- Generated from pipeline plan at 2026-06-10T14:04:43Z
- Pipeline will update status as tasks complete
