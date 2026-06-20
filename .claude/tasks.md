# Tasks — Pipeline Pre-Flight Health Validator

## Status: In Progress
Pipeline: standard | Branch: ci/pipeline-pre-flight-health-validator-674

## Checklist
- [ ] Task 1: Create `scripts/lib/pipeline-preflight.sh` with load guard + `PREFLIGHT_REASONS`. *(blocks 2-7)*
- [ ] Task 2: Implement `check_disk_space()` (config-driven 5GB, numeric-guarded, cross-platform `df`).
- [ ] Task 3: Implement `check_claude_auth()` with actionable fix.
- [ ] Task 4: Implement `check_network()` (skips offline/local; curl-optional).
- [ ] Task 5: Implement `check_tmux()` (non-blocking warn).
- [ ] Task 6: Implement `check_github_rate_limit()` with retry-in-N-minutes message (NO_GITHUB guarded, fail-open on query error).
- [ ] Task 7: Implement `preflight_health_check()` orchestrator + `preflight.failed`/`passed` events. *(blocks 8,11,12)*
- [ ] Task 8: Create standalone `scripts/sw-preflight.sh` CLI (VERSION, `--json`, `--help`).
- [ ] Task 9: Add `--skip-preflight` to `parse_args()` in `pipeline-cli.sh`.
- [ ] Task 10: Declare `SKIP_PREFLIGHT=false` + source new lib in `sw-pipeline.sh`.
- [ ] Task 11: Add gated `preflight_health_check` call in `pipeline-commands.sh` before line 730.
- [ ] Task 12: Create `scripts/sw-preflight-test.sh` with mocked-environment scenarios.
- [ ] Task 13: Register test in `package.json` test script (alphabetical).
- [ ] Task 14: Update `.claude/CLAUDE.md` AUTO tables; verify `--help`/router discoverability.
- [ ] Task 15: Run `bash scripts/sw-preflight-test.sh` and full `npm test`; fix regressions.
- [ ] `preflight_health_check()` checks GitHub rate limits, disk (>5GB default, config-driven),
- [ ] `shipwright pipeline start` runs the check before launch and blocks on a blocking failure.
- [ ] `--skip-preflight` bypasses all checks.
- [ ] Each failure prints an actionable fix (e.g. "GitHub API rate limited, retry in 23 minutes").
- [ ] `preflight.failed` event emitted to `events.jsonl` with reasons (and `preflight.passed` on success).

## Notes
- Generated from pipeline plan at 2026-06-20T01:35:49Z
- Pipeline will update status as tasks complete
