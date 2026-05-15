---
goal: "Pre-Flight Issue Feasibility Validator — Catch Doomed Pipelines Before They Start

IMPORTANT — Previous build attempt failed tests. Fix these errors:
  [38;2;0;212;255m▸[0m Heartbeat update overwrites existing... [38;2;74;222;128m✓[0m
  [38;2;0;212;255m▸[0m Check missing heartbeat returns error... [38;2;74;222;128m✓[0m
  [38;2;0;212;255m▸[0m Heartbeat dir auto-created when missing... [38;2;74;222;128m✓[0m

[38;2;168;85;247m[1mCheckpoint Lifecycle[0m
  [38;2;0;212;255m▸[0m Checkpoint save creates JSON file... ✓ Checkpoint saved for stage build (iteration 5)
[38;2;74;222;128m✓[0m
  [38;2;0;212;255m▸[0m Checkpoint restore outputs JSON... ✓ Checkpoint saved for stage test (iteration 3)
[38;2;74;222;128m✓[0m
  [38;2;0;212;255m▸[0m Checkpoint restore missing stage fails... [38;2;74;222;128m✓[0m
  [38;2;0;212;255m▸[0m Checkpoint clear removes file... ✓ Checkpoint saved for stage review (iteration 1)
✓ Cleared checkpoint for stage review
[38;2;74;222;128m✓[0m
  [38;2;0;212;255m▸[0m Checkpoint clear --all removes all... ✓ Checkpoint saved for stage build (iteration 1)
✓ Checkpoint saved for stage test (iteration 2)
✓ Cleared 2 checkpoint(s)
[38;2;74;222;128m✓[0m
  [38;2;0;212;255m▸[0m Checkpoint save with files-modified... ✓ Checkpoint saved for stage build (iteration 7)
[38;2;74;222;128m✓[0m

[38;2;168;85;247m[1mIntegration[0m
  [38;2;0;212;255m▸[0m Pipeline script has heartbeat functions... [38;2;74;222;128m✓[0m
  [38;2;0;212;255m▸[0m Loop script has heartbeat and checkpoint... [38;2;74;222;128m✓[0m
  [38;2;0;212;255m▸[0m Pipeline has human intervention checks... [38;2;74;222;128m✓[0m

[38;2;0;212;255m[1m════════════════════════════════════════════════════[0m
[38;2;74;222;128m[1m  All 17 tests passed ✓[0m
[38;2;0;212;255m[1m════════════════════════════════════════════════════[0m

sw-hello-test.sh

Focus on fixing the failing tests while keeping all passing tests working.

## Plan Summary
# Implementation Plan — Pre-Flight Issue Feasibility Validator (#488)

## Brainstorming / Socratic Refinement

### Requirements Clarity
- **MVP**: A single entry-point (`preflight_validate`) called by `shipwright pipeline start` and by the daemon spawn path that runs five named checks (git, issue clarity, deps, test command, concurrent pipelines), emits a structured JSON verdict, writes a markdown rejection report on failure, and records rejections to the memory system.
- **Implicit requirements**: must be skippable (`--force` / `SW_PREFLIGHT_ENABLED=false`); must respect `NO_GITHUB`; must not duplicate the existing post-intake `feasibility_gate` in `pipeline-feasibility.sh` — pre-flight runs *before* intake.
- **Acceptance criteria** (in addition to issue): >30% reduction in failed pipeline starts (tracked by comparing `preflight.reject` events to `pipeline.failed_start` baseline); rejections labeled `pipeline/preflight-rejected` on GitHub; verdict + reasons written to memory.

### Design Alternatives
1. **New focused library `scripts/lib/pipeline-preflight.sh` + thin CLI `scripts/sw-preflight.sh`** *(chosen)* — single new lib, reuses `feasibility_score`, `preflight_checks` (tool detection), and memory helpers. Integration is two small call sites. Blast radius: small.
2. **Extend `pipeline-feasibility.sh` in place** — couples two concerns (post-intake scoring vs pre-pipeline gating). Rejected: violates single-responsibility, harder to test, hidden side effects on existing stages.
3. **Inline checks into `sw-daemon.sh` and `sw-pipeline.sh`** — rejected: duplicates logic across spawn paths, hard to unit-test, scattered tests required.

### Risk Assessment / Mitigation
| Risk | Impact | Mitigation |
|---|---|---|
| False positives starve daemon | Pipelines never spawn | Configurable `min_score` + `--force` flag + `preflight.degraded` events for tuning |
| Test-command validity probe is slow | Daemon spawn latency | Static parse only (read `package.json` `scripts.test`, no install/run) |
| Concurrent-pipeline lock false positives | Worktree spawns blocked | Detect via `~/.shipwright/heartbeats/` AND `git worktree list`, key by `issue=` |
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Pre-Flight Issue Feasibility Validator — Catch Doomed Pipelines Before They Start
## Context
## Decision
## Alternatives Considered
## Implementation Plan
## Component Diagram
## Interface Contracts
## Data Flow
## Error Boundaries
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Pre-Flight Issue Feasibility Validator — Catch Doomed Pipelines Before They Start

### Goals
- Validator checks git state, issue clarity score, dependency availability, test command validity
- Rejects pipelines that would obviously fail, with actionable error messages
- Logs rejection reasons to memory system for pattern analysis
- Integrates with daemon spawn logic (run before creating pipeline)
- Reduces failed pipeline starts by >30% within first week
- **Priority**: P0
- **Complexity**: standard
- **Generated by**: Strategic Intelligence Agent
- **Strategy alignment**: P0: Reliability & Success Rate

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json (detailed, 6 entries)",
      "relevance": 95,
      "summary": "Directly documents heartbeat detection logic failure, regression test JSON output issues, and empty confidence value bug in jq—all matching test areas now passing in context (heartbeat tests, checkpoint tests)"
    },
    {
      "file": "patterns.json (project conventions)",
      "relevance": 80,
      "summary": "Confirms Node.js/vitest project structure with CommonJS imports and src/ source directory—essential for understanding test conventions and file organization"
    },
    {
      "file": "success-patterns.json",
      "relevance": 75,
      "summary": "Shows previous bug fixes used 3 iterations with loop-based approach; current build is iteration 7—provides context for iteration patterns and testing strategy used in this repo"
    },
    {
      "file": "metrics.json (baselines)",
      "relevance": 60,
      "summary": "Baseline build duration of 3692s provides performance context to evaluate if current pipeline is executing within expected bounds"
    },
    {
      "file": "issues.json",
      "relevance": 50,
      "summary": "Records past issues including timeout bugs and success patterns; shows how similar failures were resolved, though less directly applicable than test failure patterns"
    }
  ]
}

Discoveries from other pipelines:
▸ No new discoveries to inject

Task tracking (check off items as you complete them):
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

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **collection-system-validation**: Validate heterogeneous system state checks (git cleanliness, dependency availability, test command syntax, issue clarity) across different subsystems.
- **pre-flight-validation-pattern**: Implement pre-flight validation checks with actionable rejection reasons, integration with daemon spawn, and memory logging for pattern analysis.

## Collection System Validation & Auto-Repair

### Core Responsibility
Design and implement validators that check heterogeneous data collection systems (events.jsonl, pipeline state, DORA metrics, cost tracking, memory patterns) for health, detect gaps systematically, and safely auto-repair broken collectors.

### Multi-System Validation Architecture

**System-Specific Validators**
- Events system: Check events.jsonl writes, verify timestamps are recent, detect missing event types (pipeline_start, pipeline_complete, stage_start)
- Pipeline state: Verify .claude/pipeline-state.md writes work, timestamps are fresh
- Cost tracking: Validate ~/.shipwright/costs.json updates, compare against expected frequency
- DORA metrics: Check metrics.json is populated, has recent data points
- Memory system: Validate memory files created, readable, contain valid patterns

**Gap Detection Patterns**
- Missing events for active pipelines (spawn time + expected stages = missing events)
- Stale timestamps (last write > threshold, e.g., 24h)
- Unreachable files (ENOENT, EPERM on expected paths)
- Incomplete writes (truncated JSON, missing closing braces)
- Permission issues (ls -l reveals 000 or other broken states)

**Health Scoring**
- Per-system: 0-100 based on recency, write success rate, completeness
- Overall: Weighted average (events 30%, state 25%, cost 15%, DORA 20%, memory 10%)
- Thresholds: Critical (<30), Warning (30-70), Healthy (>70)

### Auto-Repair Strategies (Safety First)

**File System Repairs**
- Fix permissions: `chmod 755 ~/.shipwright/` (idempotent, safe)
- Create missing dirs: `mkdir -p` on standard paths (safe if idempotent)
- Cleanup truncated files: Back up to `.bak`, recreate empty or last-known-good version
- Rotate stale logs: Move logs >30d to archive (preserve data)

**Collector Restarts**
- Daemon restart: Signal SIGHUP, not SIGKILL (graceful)
- Loop restart: Only if process is hung (check for zombie)
- Checkpoint restore: Use last valid state from .claude/checkpoints/ before restart

**Data Restoration**
- Never delete data unilaterally—always preserve backups
- Restore from last checkpoint if available
- If repair requires data loss, alert and wait for manual approval

### Health Reporting Format

```json
{
  "timestamp": "2026-03-10T14:23:00Z",
  "overall_health": 85,
  "systems": {
    "events": {"health": 95, "last_write": "2026-03-10T14:22:00Z", "status": "healthy"},
    "pipeline_state": {"health": 80, "last_write": "2026-03-10T14:21:00Z", "status": "warning", "gaps": ["build stage missing"]},
    "cost_tracking": {"health": 100, "last_write": "2026-03-10T14:20:00Z", "status": "healthy"},
    "dora_metrics": {"health": 60, "last_write": "2026-03-10T12:00:00Z", "status": "warning", "stale_hours": 2},
    "memory": {"health": 90, "status": "healthy"}
  },
  "repairs_attempted": [{"system": "dora", "action": "chmod 755", "success": true}],
  "alerts": ["DORA metrics not updated in 2 hours"]
}
```

### Patrol Integration

**Daily Validation Run**
- Schedule: 02:00 UTC (off-peak, before metrics review)
- Runs: `shipwright metrics validate --repair` (auto-repair enabled in daemon)
- Output: JSON + summary logged to events.jsonl with type `metrics_validation`

**Alert Thresholds**
- Overall health < 70: Alert to patrol log, escalate for manual review
- Missing events > 5 consecutive runs: Critical alert
- Permission failures: Attempt repair, alert if repair fails

**Repair Decision Logic**
- Low-risk repairs (permissions, mkdir): Auto-execute
- Medium-risk (truncated file cleanup): Log and alert, wait 10 min for manual override, then auto-execute
- High-risk (collector restart): Alert and wait for approval, or skip if patrol is in critical path

### Testing Strategy

**Unit Tests per Validator**
- events.jsonl: Simulate ENOENT, EPERM, truncated JSON, missing event types
- State file: Simulate stale timestamp, missing fields
- Cost tracker: Simulate missing file, zero events
- DORA: Simulate outdated metrics.json, malformed JSON
- Memory: Simulate unreadable patterns, corrupted files

**Integration Test (Proof of Repair)**
[... skills truncated: 8265→8000 chars ...]
**Negative Tests**
- High-risk repairs skipped correctly when approval not given
- Repair doesn't cause data loss (backups preserved)
- Validator doesn't create false positives on legitimate stale data (e.g., idle repos)

## Pre-Flight Validation Pattern

Pre-flight validation catches fundamentally broken pipelines before they consume resources, time, and quota. This pattern guides implementing a multi-check validator that integrates cleanly with daemon spawn logic and provides actionable rejection feedback.

### Core Checks

**Git State Validation**
- Verify working tree is clean (`git status --porcelain`)
- Check no concurrent pipelines on the same branch
- Validate repo is initialized and has commits
- For monorepos: verify the target package exists

**Issue Clarity Scoring**
- Check issue title is present and >10 characters
- Verify issue body exists and describes actionable scope
- Score clarity as (title_length + body_word_count + criteria_count) / 3
- Reject if score < 20 (too vague to execute reliably)

**Dependency Availability**
- Check `package.json` parse-able; `npm ls` succeeds without errors
- Verify test runner exists (`vitest`, `jest`, `mocha` etc.)
- Check lockfile consistency (`package-lock.json` or `yarn.lock` matches HEAD)
- For compiled languages: verify build tools in PATH

**Test Command Validity**
- Parse test command from package.json `test` script
- Validate test command syntax (no unmatched quotes, pipes)
- Check test runner binary is executable
- Dry-run test command with `--help` or `--list` to verify it's recognized

### Rejection Messages

Every rejection must include:
- What failed (specific check)
- Why it matters (prevents what kind of failure)
- How to fix it (actionable step)

**Example**: 
```
✗ Git working tree is dirty
  Why: Daemon pipeline will fail during commit because there are uncommitted changes.
  Fix: Run 'git status' and commit or stash your changes, then retry.
```

### Memory System Integration

Log rejections with structured data:
```json
{
  "timestamp": "2026-05-15T18:55:10Z",
  "check": "git_state",
  "reason": "working_tree_dirty",
  "issue_id": "488",
  "count": 1
}
```

The memory system aggregates these to detect patterns (e.g., "80% of rejections are dirty git states on Monday mornings" → suggest pre-commit hooks).

### Daemon Spawn Integration

Run validator in daemon spawn path BEFORE creating pipeline:
```bash
# In sw-daemon.sh, before spawn_pipeline:
if ! validate_pre_flight "$issue_id" "$branch"; then
  log_rejection "$issue_id" "$reason"
  update_issue "$issue_id" "Pipeline rejected: $reason. Fix and re-run."
  continue  # Skip to next issue
fi
```

Do NOT block the spawn thread — run validation in parallel and queue the result.

### Edge Cases

- **Monorepos**: Validate target package exists before checking dependencies
- **Conditional dependencies**: If package.json has postinstall/prepare scripts, pre-flight must run them
- **Flaky tests**: Don't reject based on test passing; only validate test command is valid
- **Stale lockfiles**: Allow if lockfile is older than package.json (indicates dev hasn't committed yet)
- **Private packages**: Skip npm registry checks; only validate local availability

### Metrics

Track over time:
- Rejection rate by check type
- False positive rate (rejected pipelines that would have succeeded)
- Time saved by preventing wasted runs
- Convergence: as patterns improve, rejection rate should drop
"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-05-15T20:19:17Z
last_iteration_at: 2026-05-15T20:19:17Z
consecutive_failures: 0
total_commits: 0
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

