---
goal: "E2E test: add comment to README [automated]

## Specification: E2E test: add comment to README [automated]

### Goals
- E2E test: add comment to README [automated]

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "test-repo-complexity/success-patterns.json",
      "relevance": 95,
      "summary": "Low complexity build fix with 1 iteration, npm test strategy, scripts/test.sh pattern — exact match for simple E2E test scenario"
    },
    {
      "file": "index.json",
      "relevance": 88,
      "summary": "Build stage test_failure pattern seen 5 times with concrete fix (timeout adjustment) — proven pattern for test execution issues"
    },
    {
      "file": "test-repo-ranking/success-patterns.json",
      "relevance": 85,
      "summary": "Two low complexity build patterns with 1 iteration each, npm test strategy — directly applicable baseline for simple builds"
    },
    {
      "file": "test-repo-corrupt/success-patterns.json",
      "relevance": 82,
      "summary": "Two build stage patterns, low complexity, 1 iteration each, npm test — consistent pattern for minimal-change builds"
    },
    {
      "file": "hash-consistency-repo/success-patterns.json",
      "relevance": 80,
      "summary": "Build stage low complexity pattern, 1 iteration, npm test with scripts/test.sh — aligned with E2E test build expectations"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 5 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Pre-Build Diff-Size and Iteration-Velocity Anomaly Warning in Pipeline Vitals — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Pre-Build Diff-Size and Iteration-Velocity Anomaly Warning in Pipeline Vitals

## Implementation Checklist
- [ ] `sw-pipeline-vitals.sh` reads `build.diff_lines` / `build.iterations` from `~/.shipwright/baselines/default.json`
- [ ] Threshold multiplier read via `_smart_int "vitals.anomaly_multiplier" 3` (env + daemon-config overridable)
- [ ] `shipwright vitals` prints an `Anomaly` warning line for an in-progress pipeline over threshold, and prints nothing when under
- [ ] `pipeline_compute_vitals --json` contains an `.anomaly` object; `--anomaly` mode works; `--help` documents it
- [ ] `pipeline_vitals_anomaly` written to `events.jsonl` exactly once per (issue, kind), not per poll
- [ ] `build.diff_lines` / `build.iterations` baselines are recorded on build-stage completion
- [ ] Cold start (`count < 3`), missing baseline, malformed baseline, and zero baseline never flag and never fail
- [ ] `health_score`, verdicts, and the daemon gate are byte-for-byte unchanged when no anomaly is present
- [ ] `scripts/sw-pipeline-vitals-test.sh` passes with the 10 new cases; existing 10 still pass
- [ ] `shellcheck` clean on both changed scripts; bash 3.2 compatible (no `declare -A`, no `readarray`, no `${var,,}`)
- [ ] `npm test` green
- [ ] `.claude/CLAUDE.md` documents the `vitals` config block (hand-written region only)

## Context
- Pipeline: standard
- Branch: feat/pre-build-diff-size-and-iteration-veloci-3313
- Issue: #3313
- Generated: 2026-08-29T13:31:40Z"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-08-29T13:55:47Z
last_iteration_at: 2026-08-29T13:55:47Z
consecutive_failures: 0
total_commits: 0
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

