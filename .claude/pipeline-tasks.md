# Pipeline Tasks — Adaptive Build-Loop Iteration Budget from Historical Outcomes

## Implementation Checklist
- [ ] **T1** — Compute `ADAPTIVE_COHORT` unconditionally in `apply_adaptive_budget()`; keep budget application behind the opt-in guard
- [ ] **T2** — Add `cohort=` to the `loop.iteration_complete` emission *(depends on T1)*
- [ ] **T3** — Rewrite `_iter_samples_for_cohort()`: single `jq -R --arg` pass, `fromjson?`, `tail` bounds
- [ ] **T4** — Rewrite `_iter_samples_global()`: same single-pass shape + `fromjson?` guard + scan bound
- [ ] **T5** — Add `ITERATIONS_SCAN_LINES`; wire `ITERATIONS_LOOKBACK` *(depends on T3, T4)*
- [ ] **T6** — Replace hardcoded 5/3 with named constants; delete unused threshold constants and `SC2034` disables
- [ ] **T7** — Add `ADAPTIVE_TIER` / `ADAPTIVE_SAMPLES` globals to `adaptive_iterations_suggest()` *(depends on T6)*
- [ ] **T8** — Extend `loop.budget_selected` emission with `tier` + `sample_count` *(depends on T7)*
- [ ] **T9** — Update `config/event-schema.json`; run `sw-event-schema-sync.sh` to confirm zero drift *(depends on T2, T8)*
- [ ] **T10** — Add cohort round-trip test (emit → read back, proving G1 fixed) *(depends on T2)*
- [ ] **T11** — Add adversarial-label test: labels with `"`, `\`, `$`, backtick *(depends on T3)*
- [ ] **T12** — Add lookback-bound test: 10k-line events file, assert bounded samples + runtime < 5s *(depends on T5)*
- [ ] **T13** — Register test suite in `package.json` `test:legacy-chain`
- [ ] **T14** — Update `.claude/CLAUDE.md` (Loop Configuration table + `AUTO:test-suites`)
- [ ] **T15** — Run `shellcheck` on both changed scripts; run `sw-adaptive-iterations-test.sh` + `sw-loop-test.sh`
- [ ] `loop.iteration_complete` carries a `cohort` field; a fresh loop run's events are consumable by `_iter_samples_for_cohort` (**G1 closed, proven by T10**)
- [ ] No jq program is built by string interpolation anywhere in `adaptive-iterations.sh`; all values pass via `--arg` (**G2 closed**)
- [ ] `_iter_samples_for_cohort` and `_iter_samples_global` each spawn exactly one `jq`; a 10k-line events file resolves in < 5s (**G3 closed**)
- [ ] `scripts/sw-adaptive-iterations-test.sh` runs in `npm test` via `test:legacy-chain` (**G4 closed**)
- [ ] Test suite passes with **0 failures** and ≥ 38 assertions, including cohort round-trip, adversarial-label, and lookback-bound cases

## Context
- Pipeline: standard
- Branch: feat/adaptive-build-loop-iteration-budget-fro-1502
- Issue: #1502
- Generated: 2026-08-08T02:38:06Z
