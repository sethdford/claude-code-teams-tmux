# Tasks — Pre-Flight Issue Feasibility Validator — Catch Doomed Pipelines Before They Start

## Status: In Progress
Pipeline: standard | Branch: ci/pre-flight-issue-feasibility-validator-c-488

## Checklist
- [ ] **Task 1**: Create `scripts/lib/pipeline-preflight.sh` skeleton (header, VERSION, sourcing).
- [ ] **Task 2**: Implement `check_git_state`. *(blocks Task 7)*
- [ ] **Task 3**: Implement `check_issue_clarity` reusing feasibility helpers. *(blocks Task 7)*
- [ ] **Task 4**: Implement `check_dependencies` (static parse). *(blocks Task 7)*
- [ ] **Task 5**: Implement `check_test_command`. *(blocks Task 7)*
- [ ] **Task 6**: Implement `check_no_conflicts` (heartbeats + worktree + claim lock). *(blocks Task 7)*
- [ ] **Task 7**: Implement `preflight_validate` aggregator + atomic JSON/MD output. *(blocks Tasks 9-11)*
- [ ] **Task 8**: Implement `preflight_log_rejection` + `emit_event` integration.
- [ ] **Task 9**: Create `scripts/sw-preflight.sh` CLI wrapper.
- [ ] **Task 10**: Wire daemon spawn in `sw-daemon.sh`.
- [ ] **Task 11**: Wire `cmd_pipeline_start` + add `--force` flag in `pipeline-cli.sh`.
- [ ] **Task 12**: Register `preflight` subcommand in `scripts/sw`.
- [ ] **Task 13**: Create `scripts/sw-preflight-test.sh`; register in `package.json`.
- [ ] **Task 14**: Add config defaults to pipeline templates.
- [ ] **Task 15**: Run `shipwright docs sync`, full `npm test`, `shipwright doctor`, `shipwright templates list`; fix regressions.
- [ ] `preflight_validate` callable from any pipeline entry point with documented contract.
- [ ] Daemon refuses to spawn pipelines for BLOCK issues; labels them `pipeline/preflight-rejected`.
- [ ] `shipwright pipeline start` aborts (exit 1) on BLOCK unless `--force`.
- [ ] Rejection JSON appended to `~/.shipwright/memory/preflight-rejections.jsonl` and surfaced via `shipwright memory show`.
- [ ] `preflight.reject` / `preflight.pass` / `preflight.degraded` events emitted to `events.jsonl`.

## Notes
- Generated from pipeline plan at 2026-05-15T19:02:59Z
- Pipeline will update status as tasks complete
