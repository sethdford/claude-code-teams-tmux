# Pipeline Tasks — Detect and Auto-Resolve Duplicate/Runaway E2E Test Issue Creation

## Implementation Checklist
- [ ] `patrol_duplicate_issues` exists as a **top-level** function in `scripts/lib/daemon-patrol.sh` and groups open issues by normalized title + sorted label set.
- [ ] Groups with `count > threshold` close all but the newest member, each with an explanatory comment naming the kept issue.
- [ ] Threshold configurable via `patrol.duplicate_issue_threshold` (flat, as the issue specifies) **and** `patrol.duplicate_issues.threshold`; env override `SW_PATROL_DUPLICATE_ISSUE_THRESHOLD` works through `_smart_int`.
- [ ] `--dry-run` logs every intended closure and executes none; verified by a test asserting the `gh` mock recorded zero `issue close` invocations.
- [ ] Unit tests pass for: no duplicates (no-op), duplicates at/below threshold (no-op), duplicates above threshold (closes exactly the expected set, keeps the newest).
- [ ] Additional tests pass for: human-labelled cluster (no-op), assigned issue excluded, closure cap respected, `NO_GITHUB=true` no-op.
- [ ] `./scripts/sw-lib-daemon-patrol-test.sh` green; `npm test` green.
- [ ] `shellcheck scripts/lib/daemon-patrol.sh scripts/sw-daemon.sh` clean at the repo's existing severity level.
- [ ] `emit_event` fires `patrol.duplicate_detected`, `patrol.duplicate_closed`, `patrol.duplicate_dry_run`.
- [ ] `.claude/CLAUDE.md` documents the config keys; `shipwright docs check` exits 0.

## Context
- Pipeline: standard
- Branch: test/detect-and-auto-resolve-duplicate-runawa-3524
- Issue: #3524
- Generated: 2026-09-02T03:57:52Z
