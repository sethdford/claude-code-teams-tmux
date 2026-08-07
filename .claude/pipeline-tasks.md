# Pipeline Tasks — Quarantine E2E Test Issues From Production Issue Tracker

## Implementation Checklist
- [ ] Task 1: Add `labels.e2e_test` + `labels.quarantine` to `config/defaults.json`
- [ ] Task 2: Create `scripts/lib/issue-quarantine.sh` with fail-open `quarantine_filter_json`
- [ ] Task 3: `sw-e2e-integration-test.sh` — ensure label exists, apply it, assert it stuck
- [ ] Task 4: `daemon-poll-github.sh` — filter after `gh_record_success`, before `issue_count`
- [ ] Task 5: `sw-triage.sh` — filter `:463`, `:695`; search qualifier on `:669`
- [ ] Task 6: `sw-strategic.sh` — filter `:115`, `:116`, `:286`, `:380`, `:388`
- [ ] Task 7: Create `scripts/sw-lib-issue-quarantine-test.sh` (14 cases incl. fail-open + wiring)
- [ ] Task 8: Register suite in `package.json` and `scripts/sw-test-all.sh`
- [ ] Task 9: Document quarantine label in `.claude/CLAUDE.md` Test Harness section
- [ ] Task 10: `bash -n` + shellcheck all touched scripts
- [ ] Task 11: Run new suite + daemon/triage/strategic/poll suites
- [ ] Task 12: `npm test` green; `shipwright version check` green
- [ ] Task 13: Verify existing synthetic issues carry a quarantined label; label any strays
- [ ] `scripts/lib/issue-quarantine.sh` exists, is Bash 3.2 clean, `VERSION` matches `package.json`, idempotently sourceable
- [ ] `sw-e2e-integration-test.sh` creates its issue with the `sw:e2e-test` label and asserts the label is present on the created issue
- [ ] `daemon-poll-github.sh`, `sw-triage.sh`, `sw-strategic.sh` exclude quarantined issues by default, and the daemon's logged count reflects the post-filter set
- [ ] Exclusion is overridable via config (`labels.quarantine`) and env (`SHIPWRIGHT_LABELS_E2E_TEST`) — no hardcoded label strings at any call site
- [ ] `quarantine_filter_json` provably fails open: malformed and empty input pass through, exit 0 (cases 8–9)
- [ ] `scripts/sw-lib-issue-quarantine-test.sh` passes 14/14, registered in `package.json`
- [ ] `npm test` green; `shipwright version check` green; `bash -n` clean on all touched scripts

## Context
- Pipeline: autonomous
- Branch: ci/issue-1303
- Issue: none
- Generated: 2026-08-07T01:54:31Z
