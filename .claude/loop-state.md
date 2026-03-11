---
goal: "Pipeline Success Rate Emergency Mode - Auto-Activate Conservative Limits When Success Rate Collapses

## Plan Summary
# Plan: Pipeline Success Rate Emergency Mode

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change:** A new daemon library module that monitors rolling success rate and, when it collapses below a threshold, automatically activates conservative limits (reduced parallelism, safer template, increased retries). When success rate recovers, it auto-deactivates.

**Implicit requirements:**
- Must not interfere with existing pause/resume mechanism (they serve different purposes — pause = stop everything, emergency = slow down and be cautious)
- Must integrate with the existing poll loop cycle-based architecture
- Must emit events for observability and dashboard visibility
- Must persist emergency state across daemon restarts (atomic file, matching existing patterns)
- Must be configurable and disableable

**Acceptance criteria:**
1. When rolling success rate drops below configurable threshold (default 30%), emergency mode activates within 1-2 poll cycles
2. Emergency mode reduces MAX_PARALLEL to MIN_WORKERS (or 1)
3. Emergency mode forces template to "full" with compound_quality enabled
4. Emergency mode increases MAX_RETRIES to at least 3
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Pipeline Success Rate Emergency Mode
## Context
## Decision
### Component Architecture
### Data Flow
## Alternatives Considered
### Alternative 1: Inline into `daemon_check_degradation()`
### Alternative 2: Extend `daemon_self_optimize()` (the learning system)
### Alternative 3: New Library Module (CHOSEN) ✓
## Interface Contracts
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Contains 4 recurring test failure patterns with root causes and fixes. Directly indicates what's causing pipeline test stage failures, essential for understanding success rate collapse. Most recent failure from 2026-03-10."
    },
    {
      "file": "patterns.json (first)",
      "relevance": 48,
      "summary": "Identifies test runner (vitest), package manager (npm), test pattern (*.test.js), and project type (node). Relevant for configuring conservative test limits and understanding what affects test execution in build stage."
    },
    {
      "file": "metrics.json",
      "relevance": 12,
      "summary": "Currently empty baselines, but would be relevant for tracking pipeline success rate metrics and establishing thresholds for emergency mode activation."
    },
    {
      "file": "patterns.json (second)",
      "relevance": 10,
      "summary": "Records project_type as nodejs detected from bootstrap. Minimal relevance; basic project classification already covered in first patterns.json entry."
    },
    {
      "file": "decisions.json",
      "relevance": 8,
      "summary": "Currently empty, but would track previous decisions about conservative limits and emergency mode. Relevant only for avoiding repeated decisions during collapse scenarios."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Pipeline Success Rate Emergency Mode - Auto-Activate Conservative Limits When Success Rate Collapses — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Pipeline Success Rate Emergency Mode - Auto-Activate Conservative Limits When Success Rate Collapses

## Implementation Checklist
- [ ] Task 1: Add emergency mode defaults to `config/defaults.json`
- [ ] Task 2: Add emergency event types to `config/event-schema.json`
- [ ] Task 3: Create `scripts/lib/daemon-emergency.sh` with core functions (check, activate, deactivate, is_active, load_state, get_ceiling)
- [ ] Task 4: Integrate emergency ceiling into `daemon_auto_scale()` in `scripts/lib/daemon-poll.sh`
- [ ] Task 5: Add emergency check hook into `daemon_check_degradation()` in `scripts/lib/daemon-poll-health.sh`
- [ ] Task 6: Add periodic emergency check to poll loop in `scripts/lib/daemon-poll.sh`
- [ ] Task 7: Source daemon-emergency.sh and add startup state loading in `scripts/sw-daemon.sh`
- [ ] Task 8: Add `emergency` CLI subcommand to `scripts/sw-daemon.sh`
- [ ] Task 9: Show emergency state in `scripts/sw-status.sh` dashboard
- [ ] Task 10: Create test suite `scripts/sw-emergency-mode-test.sh` with 13 test cases
- [ ] Task 11: Register test in `package.json`
- [ ] Task 12: Run full test suite and fix any regressions
- [ ] Emergency mode activates automatically when rolling success rate ≤ 30% (configurable)
- [ ] Emergency mode reduces MAX_PARALLEL to MIN_WORKERS
- [ ] Emergency mode forces "full" template with compound_quality
- [ ] Emergency mode increases MAX_RETRIES to at least 3
- [ ] Emergency mode deactivates after success rate ≥ 60% sustained for 3 consecutive checks
- [ ] Hysteresis prevents oscillation (30% activate / 60% deactivate)
- [ ] Emergency state persists via flag file across daemon restarts
- [ ] Emergency state auto-expires after configurable duration (default 2h)

## Context
- Pipeline: autonomous
- Branch: ci/issue-251
- Issue: none
- Generated: 2026-03-11T01:01:59Z

## Failure Diagnosis (Iteration 2)
Classification: unknown
Strategy: retry_with_context
Repeat count: 0"
iteration: 2
max_iterations: 20
status: running
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-03-11T01:24:18Z
last_iteration_at: 2026-03-11T01:24:18Z
consecutive_failures: 0
total_commits: 2
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-03-11T01:14:01Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":317006,"duration_api_ms":298651,"num_turns":62,"resu

### Iteration 2 (2026-03-11T01:24:18Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":422615,"duration_api_ms":324886,"num_turns":102,"res

