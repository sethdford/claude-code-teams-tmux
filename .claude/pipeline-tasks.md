# Pipeline Tasks — Detect and Alert on E2E Test Issue Spam Flooding Open Issues Queue

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/issue-noise.sh` skeleton (load guard, VERSION, `_noise_cfg`)
- [ ] Task 2: Implement `noise_issue_confidence` with override-label precedence *(blocks 3, 5, 8, 11)*
- [ ] Task 3: Implement `is_noise_issue` and `noise_filter_issues`
- [ ] Task 4: Implement `noise_check_flood` with hourly alert dedupe *(depends on 3)*
- [ ] Task 5: Skip noise issues in `triage_score_issue` before the intelligence + timeline calls *(depends on 2)*
- [ ] Task 6: Filter + flood-check in `daemon_poll_github` before the scoring loop *(depends on 3, 4)*
- [ ] Task 7: Source the lib from `sw-daemon.sh` and defensively from `daemon-triage.sh`
- [ ] Task 8: Opt-in auto-close of high-confidence noise in `daemon_on_success`, fail-closed on fetch error *(depends on 2)*
- [ ] Task 9: Harden `sw-e2e-integration-test.sh` — body marker, `EXIT INT TERM` trap, stale-issue sweep
- [ ] Task 10: Filter noise from the three `sw-strategic.sh` context fetches *(depends on 3)*
- [ ] Task 11: Write `scripts/sw-lib-issue-noise-test.sh` *(depends on 2, 3, 4)*
- [ ] Task 12: Add skip + non-E2E regression cases to `sw-lib-daemon-triage-test.sh` *(depends on 5)*
- [ ] Task 13: Register the suite in `package.json`; add `noise_issues` to `config/defaults.json`
- [ ] Task 14: Document the `noise_issues` config block in `.claude/CLAUDE.md`
- [ ] Task 15: Run `npm test` for touched suites + `shipwright version check`; verify shellcheck clean
- [ ] `scripts/lib/issue-noise.sh` exists, is shellcheck-clean, bash 3.2 compatible (no `declare -A`, no `readarray`, no `${var,,}`/`${var^^}`), and has `VERSION` matching `package.json`
- [ ] `triage_score_issue` returns `0` for label-, marker-, and title-matched noise issues and emits `daemon.triage_skipped`
- [ ] Non-E2E issue scores are **byte-identical** to pre-change values (asserted numerically in `sw-lib-daemon-triage-test.sh`)
- [ ] "E2E test flake in checkout flow" (human-filed, no marker/label) is **not** detected as noise — asserted
- [ ] A noise issue carrying `p0`/`urgent`/`security` is **not** detected as noise — asserted

## Context
- Pipeline: standard
- Branch: ci/detect-and-alert-on-e2e-test-issue-spam-3108
- Issue: #3108
- Generated: 2026-08-28T03:42:45Z
