# Pipeline Tasks — Pre-Flight Issue Feasibility Validator — Catch Doomed Pipelines Before They Start

## Implementation Checklist

- [x] **Task 1**: Create `scripts/lib/pipeline-preflight.sh` skeleton (header, VERSION, sourcing).
- [x] **Task 2**: Implement `check_git_state`.
- [x] **Task 3**: Implement `check_issue_clarity` reusing feasibility helpers.
- [x] **Task 4**: Implement `check_dependencies` (static parse).
- [x] **Task 5**: Implement `check_test_command`.
- [x] **Task 6**: Implement `check_no_conflicts` (heartbeats + worktree + claim lock).
- [x] **Task 7**: Implement `preflight_validate` aggregator + atomic JSON/MD output.
- [x] **Task 8**: Implement `preflight_log_rejection` + `emit_event` integration.
- [x] **Task 9**: Create `scripts/sw-preflight.sh` CLI wrapper.
- [x] **Task 10**: Wire daemon spawn in `daemon-dispatch.sh`.
- [x] **Task 11**: Wire `pipeline_start` + add `--force` flag in `pipeline-cli.sh`.
- [x] **Task 12**: Register `preflight` subcommand in `scripts/sw`.
- [x] **Task 13**: Create `scripts/sw-preflight-test.sh`; register in `package.json`.
- [ ] **Task 14**: Add config defaults to pipeline templates (deferred — env-based control is sufficient for MVP).
- [ ] **Task 15**: Run `shipwright docs sync`, full `npm test`, `shipwright doctor`, `shipwright templates list`; fix regressions.

## Acceptance

- [x] `preflight_validate` callable from any pipeline entry point with documented contract.
- [x] Daemon refuses to spawn pipelines for BLOCK issues; labels them `pipeline/preflight-rejected`.
- [x] `shipwright pipeline start` aborts (exit 1) on BLOCK unless `--force`.
- [x] Rejection JSON appended to `~/.shipwright/memory/preflight-rejections.jsonl`.
- [x] `preflight.pass` / `preflight.warn` / `preflight.block` events emitted to `events.jsonl`.

## Context

- Pipeline: standard
- Branch: ci/pre-flight-issue-feasibility-validator-c-488
- Issue: #488
- Generated: 2026-05-15T19:02:58Z
