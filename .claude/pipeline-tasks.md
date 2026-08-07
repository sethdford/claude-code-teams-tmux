# Pipeline Tasks — Quarantine E2E Test Issues From Production Issue Tracker

## Implementation Checklist
- [x] Task 1: Fix broken `source` fallback in `lib/daemon-poll-github.sh:7`; remove the error-swallowing `|| true`
- [x] Task 2: Source `issue-quarantine.sh` in the consumer scripts lacking it
- [x] Task 3: Filter `sw-decide.sh:66` dedup query
- [x] Task 4: Filter `sw-autonomous.sh` dedup searches (3 sites)
- [x] Task 5: Filter `lib/root-cause.sh:188` error-signature dedup (add `--json number,labels`)
- [x] Task 6: Filter `sw-patrol-meta.sh:44` and `sw-strategic.sh:655` title dedup
- [x] Task 7: Filter `lib/daemon-triage.sh:463` triage score fetch
- [x] Task 8: Filter `sw-release-manager.sh:166` blocker count
- [x] Task 9: Convert `lib/fleet-failover.sh:25` to `quarantine_search_qualifier` with empty-guard
- [x] Task 10: Audit every modified site for `labels` in the `--json` field list
- [x] Task 11: Add `shipwright triage quarantine list|apply` with dry-run default
- [x] Task 12: Add quarantine validation section to `sw-doctor.sh`
- [x] Task 13: N/A — sw-tracker-providers-test.sh uses a mock `gh`; it never creates real issues
- [x] Task 14: Add regression test — library loads with `SCRIPT_DIR` unset — plus backfill-selector tests
- [x] Task 15: Correct consumption-site count and consumer list in `.claude/CLAUDE.md`
- [x] `lib/daemon-poll-github.sh` sources the library by self-relative path; a regression test proves it loads with `SCRIPT_DIR` unset
- [x] All previously-unfiltered consumers filter quarantined issues; every one requests `labels` in its `--json` fields
- [x] Every new filter site is fail-open: malformed JSON yields unfiltered input and exit 0, verified by test
- [x] `shipwright triage quarantine list` reports unlabeled synthetic issues; `apply` is dry-run unless `--apply` is passed
- [x] `shipwright doctor` reports quarantine config health

## Context
- Pipeline: autonomous
- Branch: ci/issue-1303
- Issue: none
- Generated: 2026-08-07T11:52:33Z
