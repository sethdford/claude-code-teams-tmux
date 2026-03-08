# Tasks — Pipeline Failure Auto-Diagnostic Report Generator

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-231

## Checklist
- [ ] Task 1: Create `scripts/sw-diagnose.sh` with boilerplate, argument parsing, help text, and data path constants
- [ ] Task 2: Implement `section_pipeline_overview()` — parse pipeline-state.md for status, stages, timing
- [ ] Task 3: Implement `section_error_analysis()` — aggregate error-log.jsonl by type with counts and distribution
- [ ] Task 4: Implement `section_root_cause()` — classify primary failure cause using lib/root-cause.sh
- [ ] Task 5: Implement `section_timeline()` — reconstruct chronological event timeline from events.jsonl + heartbeats
- [ ] Task 6: Implement `section_memory_matches()` — match current errors against known failure patterns in memory
- [ ] Task 7: Implement `section_recommendations()` — synthesize actionable recommendations from all sections
- [ ] Task 8: Implement `cmd_report()` orchestrator with text and JSON output modes, file persistence, and event emission
- [ ] Task 9: Implement `cmd_timeline()` subcommand for focused timeline view
- [ ] Task 10: Implement `cmd_recommend()` subcommand for action-focused output
- [ ] Task 11: Register `diagnose|diag` command in `scripts/sw` CLI router
- [ ] Task 12: Write `scripts/sw-diagnose-test.sh` test suite with >=15 test cases
- [ ] Task 13: Register test suite in `package.json`
- [ ] Task 14: Run `shipwright docs sync` to update CLAUDE.md AUTO sections
- [ ] `shipwright diagnose` executes without error and produces a diagnostic report
- [ ] `shipwright diagnose --json` produces valid JSON parseable by `jq`
- [ ] Report includes all 6 sections: pipeline overview, error analysis, root cause, timeline, memory matches, recommendations
- [ ] Empty/missing data files produce graceful "no data" messages, not crashes
- [ ] `--artifacts-dir` flag allows targeting arbitrary pipeline runs
- [ ] `--limit N` flag controls error output volume

## Notes
- Generated from pipeline plan at 2026-03-08T06:53:41Z
- Pipeline will update status as tasks complete
