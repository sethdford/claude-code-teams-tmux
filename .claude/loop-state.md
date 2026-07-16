---
goal: "Build Loop Error Repetition Detector with Auto-Escalation

## Plan Summary
# Implementation Plan: Build Loop Error Repetition Detector with Auto-Escalation

## Summary

Add a dedicated component that detects when the **same error recurs across build-loop
iterations** (using a *normalized* error signature) and drives a graduated
**auto-escalation ladder** — inject a stronger targeted hint → bump reasoning effort →
switch to a stronger/fallback model → force a session restart → abort and flag for human.

The build loop (`scripts/sw-loop.sh`) already has several *partial, disconnected*
mechanisms for this. The core of this feature is a small new library that (a) provides a
**stable normalized signature** better than the existing raw-`md5` fingerprint, and
(b) wires the existing escalation primitives into a single, testable escalation ladder
that responds specifically to *repetition*, not just to low progress.

---

## Requirements Clarity (Socratic answers)

**Minimum viable change.** A new lib `scripts/lib/loop-error-repetition.sh` sourced by
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Build Loop Error Repetition Detector with Auto-Escalation
## Context
## Decision
### Component Diagram
### Interface Contracts
### Data Flow
### Error Boundaries
## Alternatives Considered
## Implementation Plan
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Build Loop Error Repetition Detector with Auto-Escalation

### Goals
- Build Loop Error Repetition Detector with Auto-Escalation

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "knowledge.json",
      "relevance": 92,
      "summary": "Contains structured error signatures, fix strategies, and failure taxonomy with occurrence metrics. Directly applicable for building error repetition detector — provides patterns on what errors repeat and how often."
    },
    {
      "file": "issues.json",
      "relevance": 87,
      "summary": "Real examples of recorded issues with error types, outcomes, and success patterns. Shows timeout bugs and semaphore solutions — directly informs error detection and auto-escalation logic."
    },
    {
      "file": "success-patterns.json (main repo, Fix bug pattern)",
      "relevance": 78,
      "summary": "Shows successful 3-iteration fix patterns with complexity metrics and file change patterns. Demonstrates how build loops converge — essential for detecting non-convergence and escalation triggers."
    },
    {
      "file": "patterns.json",
      "relevance": 72,
      "summary": "Project conventions (vitest, Node, commonjs) define where to implement detector code and how it integrates with existing build loop infrastructure."
    },
    {
      "file": "metrics.json",
      "relevance": 68,
      "summary": "Baseline build_duration_s (2089s) provides empirical threshold for escalation — helps distinguish normal builds from truly stuck loops requiring intervention."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Build Loop Error Repetition Detector with Auto-Escalation — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Build Loop Error Repetition Detector with Auto-Escalation

## Implementation Checklist
- [ ] Task 1: Implement `ler_normalize_signature` (strip line#/hex/ts/pid/path; category+hash)
- [ ] Task 2: Implement `ler_record_and_count` (atomic tmp+mv, jq-absent fallback, reset semantics)
- [ ] Task 3: Implement `ler_decide_escalation` ladder (hint→effort→model→restart→abort) + config toggles
- [ ] Task 4: Implement `ler_current_signature` + `ler_run` orchestrator with `emit_event`
- [ ] Task 5: Source module in `sw-loop.sh` and call after `write_error_summary`
- [ ] Task 6: Apply escalation directives + add `error_repetition` status case + bump `VERSION`
- [ ] Task 7: Add `loop.error_repetition` defaults to `daemon-config.json`
- [ ] Task 8: Document config keys in `.claude/CLAUDE.md` Loop Configuration
- [ ] Task 9: Write `scripts/sw-lib-loop-error-repetition-test.sh` (normalize, count, reset, ladder, atomicity, no-jq)
- [ ] Task 10: Register test in `package.json`
- [ ] Task 11: `shipwright version check` passes (VERSION sync)
- [ ] Task 12: `shellcheck` clean (bash 3.2); new suite + `sw-loop-test.sh` green
- [ ] Task 13: `shipwright docs sync` regenerates AUTO tables
- [ ] `ler_run` detects 3 consecutive same-signature failures and emits
- [ ] Escalation ladder advances one rung per crossing; different error/success resets.
- [ ] `sw-loop.sh` applies each directive (verified via mocked run) without breaking the
- [ ] New test suite passes and is registered in `package.json`; **all existing tests pass**.
- [ ] `shellcheck` clean, bash 3.2 compatible; `shipwright version check` passes.
- [ ] Config documented; AUTO doc tables regenerated.

## Context
- Pipeline: autonomous
- Branch: ci/issue-770
- Issue: none
- Generated: 2026-07-16T04:08:01Z"
iteration: 1
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-07-16T04:27:14Z
last_iteration_at: 2026-07-16T04:27:14Z
consecutive_failures: 0
total_commits: 1
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-07-16T04:27:14Z)
| Config documented; config block added; events registered | ✅ |
| No TODO/FIXME/HACK/XXX in new code | ✅ |
**Notes on the two unrelated failures I encountered:** `sw-auto-recovery-test.sh` (exits 1, no output) and one assertion

