---
goal: "Failure Pattern Auto-Mitigation Engine with Memory-Driven Fix Injection

## Plan Summary
The implementation plan has been written to `.claude/pipeline-artifacts/plan.md`. Here's a summary of the key decisions:

## Plan Summary

**Architecture**: New focused library `scripts/lib/auto-mitigation.sh` (~200 lines) with 4 public functions:
- `mitigation_scan()` -- reads error-summary.json, matches against failures.json patterns with >80% effectiveness
- `mitigation_inject()` -- formats matches into prompt-ready markdown
- `mitigation_record_outcome()` -- atomically tracks attempts/successes in failures.json
- `mitigation_stats()` -- aggregates metrics for the dashboard

**Integration points** (minimal blast radius):
- `sw-loop.sh` -- source library, call before compose_prompt, record outcomes after test gate
- `loop-iteration.sh` -- inject mitigation section into prompt before memory section  
- `sw-memory.sh` -- add `mitigation_attempts`/`mitigation_success_count` to existing fix outcome tracking
- Dashboard -- new `GET /api/metrics/mitigations` endpoint + frontend rendering

**9 files touched** (2 new, 7 modified), **10 tasks**, **12 test cases**

**Key design decisions**:
- Chose new lib file over extending sw-memory.sh (already 2118 lines) -- follows existing 40+ module decomposition
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Failure Pattern Auto-Mitigation Engine with Memory-Driven Fix Injection
## Context
## Decision
### Component Diagram
### Interface Contracts
# ── auto-mitigation.sh ──
# Scan error-summary.json against failure patterns with proven fixes.
# Params:
#   $1 - path to error-summary.json (must exist, JSON with .error_lines[])
#   $2 - path to failures.json (must exist, JSON with .failures[])
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "success-patterns.json",
      "relevance": 90,
      "summary": "Contains concrete successful patterns from loop iterations with proven fixes (bc syntax, /tmp substitution, test cleanup). Direct memory of what worked in build stage—essential for injection into current build."
    },
    {
      "file": "failures.json",
      "relevance": 88,
      "summary": "Captures test stage failures with root causes (sw-cleanup dry-run mode, sed variable expansion, regression detection) and fixes. Directly applicable to mitigating similar build/test failures."
    },
    {
      "file": "failures.json",
      "relevance": 82,
      "summary": "Build stage failures with proven mitigation effectiveness: variable initialization (100% success rate, 4/4 applied), missing dependencies (95% effectiveness). High-confidence patterns for auto-mitigation."
    },
    {
      "file": "failures.json",
      "relevance": 80,
      "summary": "Build stage failure patterns with detailed mitigation tracking: uninitialized variables (100% effectiveness) and reference errors (66% effectiveness). Provides decision data for fix selection."
    },
    {
      "file": "failures.json",
      "relevance": 78,
      "summary": "Minimal but high-confidence pattern: 'cannot read property' errors with 100% fix effectiveness rate (initialize variable). Lightweight entry useful for quick failure matching during build."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Failure Pattern Auto-Mitigation Engine with Memory-Driven Fix Injection — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Failure Pattern Auto-Mitigation Engine with Memory-Driven Fix Injection

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/auto-mitigation.sh` -- blocks Tasks 3, 4, 8
- [ ] Task 2: Update `scripts/sw-memory.sh` mitigation fields
- [ ] Task 3: Integrate into `scripts/sw-loop.sh` -- depends on Task 1
- [ ] Task 4: Update `scripts/lib/loop-iteration.sh` -- depends on Task 1
- [ ] Task 5: Add MitigationStats type -- blocks Tasks 6, 7
- [ ] Task 6: Add mitigations API endpoint -- depends on Task 5
- [ ] Task 7: Add mitigation frontend rendering -- depends on Tasks 5, 6
- [ ] Task 8: Create test suite -- depends on Task 1
- [ ] Task 9: Register test and run full suite
- [ ] Task 10: Verify end-to-end flow

## Context
- Pipeline: standard
- Branch: feat/failure-pattern-auto-mitigation-engine-w-341
- Issue: #341
- Generated: 2026-04-03T18:40:17Z

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **systematic-debugging**: Pattern matching and fix injection are failure-prone; if initial implementation doesn't match failure signatures correctly, systematic investigation prevents blind retry cycles.

## Systematic Debugging: Root Cause Analysis

A previous attempt at this stage FAILED. Do NOT blindly retry the same approach. Follow this 4-phase investigation:

### Phase 1: Evidence Collection
- Read the error output from the previous attempt carefully
- Identify the EXACT line/file where the failure occurred
- Check if the error is a symptom or the root cause
- Look for patterns: is this a known error type?

### Phase 2: Hypothesis Formation
- List 3 possible root causes for this failure
- For each hypothesis, identify what evidence would confirm or deny it
- Rank hypotheses by likelihood

### Phase 3: Root Cause Verification
- Test the most likely hypothesis first
- Read the relevant source code — don't guess
- Check if previous artifacts (plan.md, design.md) are correct or flawed
- If the plan was correct but execution failed, focus on execution
- If the plan was flawed, document what was wrong

### Phase 4: Targeted Fix
- Fix the ROOT CAUSE, not the symptom
- If the previous approach was fundamentally wrong, choose a different approach
- If it was a minor error, make the minimal fix
- Document what went wrong and why the new approach is better

IMPORTANT: If you find existing artifacts from a successful previous stage, USE them — don't regenerate from scratch.

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Root Cause Hypothesis**: List 3 possible root causes ranked by likelihood with specific evidence that would confirm/deny each
2. **Evidence Gathered**: Exact file:line location of failure, error messages, logs, code examination results, artifact validation (plan.md, design.md correctness)
3. **Fix Strategy**: Description of the ROOT CAUSE fix (not the symptom), with rationale for why this approach differs from the previous failed attempt
4. **Verification Plan**: How to verify the fix works (test cases, specific checks, expected behavior confirmation)

If any section is not applicable, explicitly state why it's skipped.
"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-04-03T18:47:12Z
last_iteration_at: 2026-04-03T18:47:12Z
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

