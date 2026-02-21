# Pipeline Tasks — Build Loop Session Restart Success Pattern Analyzer

## Implementation Checklist
- [ ] Task 1: Create `sw-restart-analyzer.sh` with header, constants, sourcing
- [ ] Task 2: Implement event query functions
- [ ] Task 3: Implement `correlate_restarts_with_outcomes()`
- [ ] Task 4: Implement `compute_success_rates()`
- [ ] Task 5: Implement `classify_restart_value()` and `recommend_max_restarts()`
- [ ] Task 6: Implement `generate_report()` (text, JSON, markdown)
- [ ] Task 7: Implement CLI dispatcher (`cmd_analyze`, `cmd_report`, `cmd_recommend`, `main`)
- [ ] Task 8: Add route + help text to `scripts/sw`
- [ ] Task 9: Create test suite with harness setup
- [ ] Task 10: Implement all 17 test cases
- [ ] Task 11: Register test in `package.json`
- [ ] Task 12: Run tests and verify all pass
- [ ] `scripts/sw-restart-analyzer.sh` exists and is executable
- [ ] `shipwright restart-analyzer analyze` produces a report from events.jsonl
- [ ] Report shows success rate by failure type and by restart count
- [ ] Report classifies each failure type as helpful/wasteful/inconclusive
- [ ] Report recommends `--max-restarts` values per failure type
- [ ] `--json` output is valid JSON with all metrics
- [ ] Exit code 1 when overall restart success rate < 40%
- [ ] All 17 test cases pass

## Context
- Pipeline: standard
- Branch: feat/build-loop-session-restart-success-patte-135
- Issue: #135
- Generated: 2026-02-21T22:50:23Z
