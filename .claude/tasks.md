# Tasks — Autonomous Test Gap Filler & Platform Hygiene Agent

## Status: In Progress
Pipeline: standard | Branch: test/autonomous-test-gap-filler-platform-hygi-631

## Checklist
- [ ] Task 1: Scaffold `sw-platform-hygiene.sh` (header, helpers fallback, VERSION, `main()` dispatch, help)
- [ ] Task 2: Implement `is_sourced_only()` (fixes tracker-github false positive generally)
- [ ] Task 3: Implement `scan_tests()` with bash-3.2 integer coverage math + empty guard
- [ ] Task 4: Implement `scan_debt()` (TODO/FIXME/HACK/KLUDGE, weighted, truncation logged)
- [ ] Task 5: Implement `metrics()` atomic JSON snapshot + trend deltas + history.jsonl
- [ ] Task 6: Implement `file_issues()` deduped, `NO_GITHUB`-guarded, code links + suggested fixes
- [ ] Task 7: Implement `report()`/`auto()` and register CLI router case in `scripts/sw`
- [ ] Task 8: Write & pass `sw-tmux-role-color-test.sh` (9 color cases + default)
- [ ] Task 9: Write & pass `sw-tmux-status-test.sh` (widget outputs, version, edge case)
- [ ] Task 10: Fix patrol scanner skip + add `patrol_meta_platform_hygiene()` to `patrol_meta_run`
- [ ] Task 11: Write & pass `sw-platform-hygiene-test.sh` (scanner/debt/metrics/dry-run)
- [ ] Task 12: Register 3 tests in `package.json`; update CLAUDE.md AUTO tables
- [ ] Task 13: Run impacted suites + `shipwright version check`; confirm executable coverage = 100%
- [ ] `sw-platform-hygiene.sh` exists, `set -euo pipefail`, bash-3.2 clean, `VERSION` matches package.json, `--version`/`help` work.
- [ ] `scan-tests` excludes sourced providers and reports the correct untested-executable list/count.
- [ ] `scan-debt` detects TODO/FIXME/HACK/KLUDGE with `file:line:context`, weighted, truncation logged.
- [ ] `metrics` writes valid atomic JSON with coverage % + debt totals and computes trend vs. prior snapshot.
- [ ] `file_issues` is `NO_GITHUB`-guarded and deduped (no network in dry-run).
- [ ] `sw-tmux-role-color-test.sh` and `sw-tmux-status-test.sh` exist and pass; executable-script coverage = 100%.
- [ ] `sw-patrol-meta.sh` no longer flags `sw-tracker-github.sh`; new hygiene check runs in `patrol_meta_run` and appears in the summary.

## Notes
- Generated from pipeline plan at 2026-06-11T13:45:06Z
- Pipeline will update status as tasks complete
