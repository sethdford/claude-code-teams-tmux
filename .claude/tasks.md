# Tasks — Build Loop Error Repetition Detector with Auto-Escalation

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-770

## Checklist
- [ ] Task 1: Implement `ler_normalize_signature` (strip line#/hex/ts/pid/path; category+hash)
- [ ] Task 2: Implement `ler_record_and_count` (atomic tmp+mv, jq-absent fallback, reset semantics)
- [ ] Task 3: Implement `ler_decide_escalation` ladder (hint→effort→model→restart→abort) + config toggles
- [ ] Task 4: Implement `ler_current_signature` + `ler_run` orchestrator with `emit_event`
- [ ] Task 5: Source module in `sw-loop.sh` and call after `write_error_summary`
- [ ] Task 6: Apply escalation directives + add `error_repetition` status case + bump `VERSION`
- [ ] Task 7: Add `loop.error_repetition` defaults to `daemon-config.json`
- [ ] Task 8: Document config keys in `.claude/CLAUDE.md` Loop Configuration
- [ ] Task 9: Write `scripts/sw-lib-loop-error-repetition-test.sh` (normalize, count, reset, ladder, atomicity, no-jq)
- [ ] Task 10: Register test in `package.json`
- [ ] Task 11: `shipwright version check` passes (VERSION sync)
- [ ] Task 12: `shellcheck` clean (bash 3.2); new suite + `sw-loop-test.sh` green
- [ ] Task 13: `shipwright docs sync` regenerates AUTO tables
- [ ] `ler_run` detects 3 consecutive same-signature failures and emits
- [ ] Escalation ladder advances one rung per crossing; different error/success resets.
- [ ] `sw-loop.sh` applies each directive (verified via mocked run) without breaking the
- [ ] New test suite passes and is registered in `package.json`; **all existing tests pass**.
- [ ] `shellcheck` clean, bash 3.2 compatible; `shipwright version check` passes.
- [ ] Config documented; AUTO doc tables regenerated.

## Notes
- Generated from pipeline plan at 2026-07-16T04:08:03Z
- Pipeline will update status as tasks complete
