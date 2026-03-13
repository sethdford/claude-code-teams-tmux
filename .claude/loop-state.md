---
goal: "Platform Capability Self-Assessment Registry with Proven Pattern Boundaries

## Plan Summary


Now I have a comprehensive understanding of the codebase. Let me write the implementation plan.

---

# Implementation Plan: Platform Capability Self-Assessment Registry

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change**: A capability registry that tracks success/failure rates by task category (using the existing `detect_task_type` categories: bug, refactor, testing, security, docs, devops, migration, architecture, feature), a pre-flight check that rejects tasks below a configurable threshold, and a CLI command to view the registry. The dashboard heatmap and conservative mode are incremental additions on top.

**Implicit requirements**:
- Cold-start behavior: empty registry should allow all tasks (optimistic start)
- Minimum sample count before gating activates (avoid rejecting based on 1 failure)
- Registry must be repo-scoped (different repos have different capabilities)
- Must work with both daemon and manual pipeline invocations
- Must survive across sessions (persistent storage)
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Platform Capability Self-Assessment Registry with Proven Pattern Boundaries
## Context
## Decision
### Why this approach
### Component Diagram
### Interface Contracts
# ── sw-db.sh CRUD layer ────────────────────────────────────────────
# Atomic upsert. Uses relative increments, safe under WAL.
# success: 1 = pass, 0 = fail
# Query entries. If category omitted, returns all for repo.
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 90,
      "summary": "Project configuration essential for build stage: Node.js with vitest test runner, CommonJS imports, src/ directory structure, and *.test.js test patterns. Directly informs build and test execution."
    },
    {
      "file": "failures.json",
      "relevance": 65,
      "summary": "14-15 recent test failures affecting sw-cleanup.sh and sw-feedback-test.sh. Provides patterns to avoid during build: stale heartbeat detection issues, JSON output formatting, and mktemp directory setup."
    },
    {
      "file": "patterns.json",
      "relevance": 28,
      "summary": "Minimal bootstrap confirmation: project_type is nodejs. Redundant with detailed patterns.json but confirms detection methodology."
    },
    {
      "file": "global.json",
      "relevance": 12,
      "summary": "Empty cross-repo learnings and common patterns. Structure exists but contains no actionable insights for this build stage."
    },
    {
      "file": "decisions.json",
      "relevance": 8,
      "summary": "Empty decisions array. No prior architectural or implementation decisions captured to inform current build stage work."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Platform Capability Self-Assessment Registry with Proven Pattern Boundaries — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Platform Capability Self-Assessment Registry with Proven Pattern Boundaries

## Implementation Checklist
- [ ] Task 1: Add `capability_registry` table + schema v7 migration + DB CRUD functions to `sw-db.sh`
- [ ] Task 2: Create `scripts/lib/capability-registry.sh` with core logic (check, record, conservative mode)
- [ ] Task 3: Add `--override-capability-check` flag to `scripts/lib/pipeline-cli.sh`
- [ ] Task 4: Integrate capability pre-flight check into `scripts/lib/pipeline-util.sh` `preflight_checks()`
- [ ] Task 5: Integrate capability pre-flight check into `scripts/lib/daemon-state.sh` `preflight_checks()`
- [ ] Task 6: Record capability outcomes in `scripts/lib/pipeline-commands.sh` (success + failure paths)
- [ ] Task 7: Create `scripts/sw-capability.sh` CLI command (show, heatmap, reset, configure, status)
- [ ] Task 8: Register `capability` subcommand in `scripts/sw` CLI router
- [ ] Task 9: Add `GET /api/capabilities` endpoint to `dashboard/server.ts`
- [ ] Task 10: Create `scripts/sw-capability-test.sh` test suite with mock registry
- [ ] Task 11: Register test in `package.json`
- [ ] Task 12: Run test suite and fix any failures
- [ ] `capability_registry` table exists in SQLite schema v7
- [ ] `sw capability show` displays registry entries with success rates
- [ ] `sw capability heatmap` shows terminal-colored category heatmap
- [ ] Pre-flight check rejects tasks with <50% success rate (when >=5 samples)
- [ ] Pre-flight check passes when registry is empty (cold start)
- [ ] Pre-flight check passes when `--override-capability-check` is used
- [ ] Pipeline completion auto-updates registry (both success and failure)
- [ ] Conservative mode activates when overall success rate <70%

## Context
- Pipeline: standard
- Branch: arch/platform-capability-self-assessment-regi-256
- Issue: #256
- Generated: 2026-03-13T15:13:57Z

## Skill Guidance (backend/infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **systematic-debugging**: Gating logic is failure-prone; systematic approach to implementation (not ad-hoc guards) reduces edge case bugs around threshold crossing and conservative mode.
- **testing-strategy**: Registry is a state machine with race conditions (concurrent updates vs. pre-flight checks); comprehensive unit tests for threshold crossing, stale reads, and atomic updates are essential.

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

## Testing Strategy Expertise

Apply these testing patterns:

### Test Pyramid
- **Unit tests** (70%): Test individual functions/methods in isolation
- **Integration tests** (20%): Test component interactions and boundaries
- **E2E tests** (10%): Test critical user flows end-to-end

### What to Test
- Happy path: the expected successful flow
- Error cases: what happens when things go wrong?
- Edge cases: empty inputs, maximum values, concurrent access
- Boundary conditions: off-by-one, empty collections, null/undefined

### Test Quality
- Each test should verify ONE behavior
- Test names should describe the expected behavior, not the implementation
- Tests should be independent — no shared mutable state between tests
- Tests should be deterministic — same result every run

### Coverage Strategy
- Aim for meaningful coverage, not 100% line coverage
- Focus coverage on business logic and error handling
- Don't test framework code or simple getters/setters
- Cover the branches, not just the lines

### Mocking Guidelines
- Mock external dependencies (APIs, databases, file system)
- Don't mock the code under test
- Use realistic test data — edge cases reveal bugs
- Verify mock interactions when the side effect IS the behavior

### Regression Testing
- Write a failing test FIRST that reproduces the bug
- Then fix the bug and verify the test passes
- Keep regression tests — they prevent the bug from recurring

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Test Pyramid Breakdown**: Explicit count of unit/integration/E2E tests and their coverage targets (e.g., "70 unit tests covering business logic, 12 integration tests for API boundaries, 3 E2E tests for critical paths")
2. **Coverage Targets**: Target coverage percentage per layer and which critical paths MUST be tested
3. **Critical Paths to Test**: Specific test cases for the happy path, 2+ error cases, and 2+ edge cases

If any section is not applicable, explicitly state why it's skipped.


## Failure Diagnosis (Iteration 2)
Classification: unknown
Strategy: retry_with_context
Repeat count: 0"
iteration: 2
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-13T16:05:24Z
last_iteration_at: 2026-03-13T16:05:24Z
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
### Iteration 1 (2026-03-13T15:35:21Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":650239,"duration_api_ms":596704,"num_turns":80,"resu

