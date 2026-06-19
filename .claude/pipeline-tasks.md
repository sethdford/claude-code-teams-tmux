# Pipeline Tasks — Semantic Issue Clustering Engine for Pattern Reuse Across Pipelines

## Implementation Checklist
- [ ] Task 1: Confirm quiet-period insertion point and config-access (`policy_get`) pattern in `scripts/lib/daemon-poll.sh`.
- [ ] Task 2: Add `clustering.enabled` read (default `false`).
- [ ] Task 3: Insert `due`→`run` block with `|| daemon_log WARN` guards and an INFO log line.
- [ ] Task 4: Add `[[ -x "$SCRIPT_DIR/sw-issue-clustering.sh" ]]` guard; verify path resolution.
- [ ] Task 5: Bump `VERSION` in `scripts/sw-daemon.sh` to match `package.json`.
- [ ] Task 6: Add daemon poll test asserting enabled→invoked / disabled→skipped via mock binary.
- [ ] Task 7: `bash scripts/sw-issue-clustering-test.sh` stays 23/0.
- [ ] Task 8: `bash scripts/sw-daemon-test.sh` (+ `sw-lib-daemon-poll-test.sh`) green.
- [ ] Task 9: `bash -n` lint on modified scripts; confirm no bash 4 constructs.
- [ ] Task 10: `shipwright docs check` reports no newly-stale sections.
- [ ] Task 11: Smoke: `clustering.enabled=true`, `re_cluster_interval_days=0`, quiet state → assert `clustering.completed` appears in `events.jsonl`.
- [ ] `scripts/lib/daemon-poll.sh` invokes `clustering due`→`run` during quiet periods only when `clustering.enabled=true`.
- [ ] Disabled (default) path adds zero external calls — verified by test.
- [ ] A clustering failure logs a WARN and the poll loop continues (no crash under `set -euo pipefail`).
- [ ] `scripts/sw-issue-clustering-test.sh` passes 23/0 (no regression).
- [ ] New daemon test passes; daemon test suites green.
- [ ] `VERSION` in `sw-daemon.sh` matches `package.json`.
- [ ] `shipwright docs check` clean; documented daemon behavior now matches code.
- [ ] `git grep clustering scripts/lib/daemon-poll.sh` shows the new wiring (gap closed).

## Context
- Pipeline: autonomous
- Branch: ci/issue-672
- Issue: none
- Generated: 2026-06-19T14:12:04Z
