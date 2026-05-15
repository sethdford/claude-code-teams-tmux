# Pipeline Tasks — Pre-Flight Issue Feasibility Validator — Catch Doomed Pipelines Before They Start

## Implementation Checklist
- [ ] T1 Create `scripts/lib/pipeline-feasibility.sh` skeleton + public stubs (blocks T2–T7)
- [ ] T2 Implement 8 heuristic checks + scoring/clamping (depends on T1)
- [ ] T3 Implement atomic JSON + Markdown report writers (depends on T1)
- [ ] T4 Implement `feasibility_gate` with `emit_event`, GH comment, BLOCK label (depends on T2, T3)
- [ ] T5 Optional LLM second-pass behind `feasibility.llm_enabled` (depends on T4)
- [ ] T6 Source new lib from bootstrap; verify load order (depends on T1)
- [ ] T7 Wire `feasibility_gate` into `stage_intake` as step 10 (depends on T4, T6)
- [ ] T8 Add doctor section validating new lib (depends on T6)
- [ ] T9 Write `sw-pipeline-feasibility-test.sh` with ≥10 cases incl. mocks (depends on T2–T7)
- [ ] T10 Register test suite in `package.json` (depends on T9)
- [ ] T11 Document `feasibility.*` defaults in CLAUDE.md feature-flags AUTO section
- [ ] T12 Run `npm test`; fix regressions
- [ ] T13 Run `shipwright docs sync` + `shipwright doctor` + `shipwright version check`
- [ ] T14 Manual smoke: short goal → BLOCK; well-formed goal → PASS
- [ ] All 8 heuristics implemented and unit-tested.
- [ ] `feasibility_gate` runs exactly once per pipeline (post-spec, pre-plan).
- [ ] BLOCK verdict produces `feasibility-report.md`, GitHub comment (when enabled), `pipeline/infeasible` label, and non-zero return that halts the pipeline cleanly.
- [ ] `feasibility.enabled=false` cleanly bypasses with no overhead.
- [ ] `npm test` green; new suite ≥10 PASSes, 0 FAILs.
- [ ] `shipwright doctor` and `shipwright version check` green.

## Context
- Pipeline: autonomous
- Branch: ci/issue-488
- Issue: none
- Generated: 2026-05-15T13:16:24Z
