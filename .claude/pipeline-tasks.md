# Pipeline Tasks — Failure Playbook Auto-Executor for Sub-30-Minute MTTR

## Implementation Checklist
- [ ] Task 1: Author `config/playbooks.json` (5 required categories + `merge-conflict` + `default` + empty `learned`). *(blocks 2–11)*
- [ ] Task 2: Scaffold `scripts/lib/playbook-executor.sh` (guard, `VERSION`, defensive sourcing, path vars).
- [ ] Task 3: `playbook_classify` reusing `recovery_classify_error` + category mapping. *(needs 2)*
- [ ] Task 4: `playbook_lookup` (jq `learned`→`playbooks`→`default`). *(needs 1,2)*
- [ ] Task 5: `playbook_execute` auto-executor (agent spawn + stage re-run + MTTR window + attempt cap). *(needs 3,4; blocks 11)*
- [ ] Task 6: `playbook_escalate` (gh comment guarded by `NO_GITHUB`, emit event). *(needs 2)*
- [ ] Task 7: `playbook_record_metric` + `playbook_metrics`/`playbook_report`. *(needs 2)*
- [ ] Task 8: `playbook_learn_from_human` (atomic read-modify-`mv` to `.learned`). *(needs 4)*
- [ ] Task 9: `scripts/sw-playbook.sh` CLI + `playbook)` router case + help banner. *(needs 2–8)*
- [ ] Task 10: Wire into `pipeline-execution.sh` self-healing path behind `PLAYBOOK_ENABLED`. *(needs 5,6,8)*
- [ ] Task 11: `scripts/sw-playbook-test.sh` — all 6 categories, lookup precedence, escalate-after-1, MTTR metric, learn-from-human. *(needs 1–8)*
- [ ] Task 12: Register test in `package.json`; sync `VERSION`; update `.claude/CLAUDE.md`; `docs sync`.
- [ ] Task 13: Run `npm test` + `./scripts/sw-playbook-test.sh`; verify no regressions in `sw-auto-recovery-test.sh` / `sw-pipeline-test.sh`.
- [ ] `config/playbooks.json` exists, parses (`jq empty`), and contains all 5 required categories + `merge-conflict` + `default`.
- [ ] `playbook_classify` maps every required error signature to the correct category (proven by tests).
- [ ] `playbook_execute` spawns an agent with failure context + playbook instructions and re-runs the target stage; success verified by the **stage's** exit code.
- [ ] Escalation fires after exactly **1** failed playbook attempt, emitting `playbook.escalated` + a human-readable summary (gh comment when `NO_GITHUB != true`).
- [ ] Learning extracts a playbook from a human fix and writes it to `.learned` atomically; reused on the next matching failure.
- [ ] MTTR-by-failure-type and playbook success rate computed and logged to `events.jsonl` (`playbook.metric`/`succeeded`/`escalated`/`learned`).
- [ ] `sw-playbook-test.sh` passes, registered in `package.json`; `npm test` green, no regressions in `sw-auto-recovery-test.sh` / `sw-pipeline-test.sh`.

## Context
- Pipeline: standard
- Branch: ci/failure-playbook-auto-executor-for-sub-3-630
- Issue: #630
- Generated: 2026-06-11T21:19:49Z
