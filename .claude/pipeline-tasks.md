# Pipeline Tasks — Add Test Coverage for sw-tracker-github.sh, sw-event-schema-sync.sh, sw-tmux-status.sh

## Implementation Checklist
- [ ] 1. Scaffold `sw-tmux-status-test.sh` (header, temp env, EXIT trap, counters)
- [ ] 2. Tests 1–2: `stage_color` / `stage_icon` full case coverage via the dispatch-stripped copy
- [ ] 3. Tests 3–6: `pipeline_widget` — absent file, parse, bold-markdown form, upward walk with sentinel
- [ ] 4. Tests 7–9: `agent_widget` — no dir, fresh, stale, mixed
- [ ] 5. Tests 10–11: dispatch modes + latency ceiling
- [ ] 6. Scaffold `sw-event-schema-sync-test.sh` with the fake-repo fixture builder
- [ ] 7. Tests 12–15: python3 guard, in-sync, drift (no-write assertion), `--write`
- [ ] 8. Tests 16–18: key extraction, dynamic types, stale preservation
- [ ] 9. Tests 19–21: counters, idempotence, nested glob
- [ ] 10. Add `GH_FAIL` branch to the existing `gh` mock in `sw-tracker-providers-test.sh`
- [ ] 11. Tests 22–24: empty-arg guards assert zero `gh` calls
- [ ] 12. Tests 25–26: `gh` failure fallbacks
- [ ] 13. Tests 27–29: label splitting, `NO_GITHUB` guards, `provider_notify` event
- [ ] 14. Register both suites in `package.json:54`; `chmod +x`
- [ ] 15. Run all three suites + `shellcheck`; run `shipwright docs sync`
- [ ] Both new suites exist, are executable, exit 0, print `PASS: n` / `FAIL: 0`
- [ ] ≥10 assertions per new suite; ≥8 new GitHub assertions
- [ ] `config/event-schema.json` unmodified after a full run (`git status` clean)
- [ ] No test invokes real `gh`, `tmux`, or network
- [ ] All three suites pass on a repo with no `.claude/pipeline-state.md` and no `~/.shipwright/`

## Context
- Pipeline: autonomous
- Branch: ci/issue-1234
- Issue: none
- Generated: 2026-08-07T01:51:48Z
