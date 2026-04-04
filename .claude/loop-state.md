---
goal: "Failure Pattern Auto-Mitigation Engine with Memory-Driven Fix Injection

## Plan Summary
The implementation plan is complete. It covers:

- **7 files** (2 new, 5 modified) with minimal blast radius
- **10 tasks** with explicit dependencies
- **New `scripts/lib/mitigation-engine.sh`** library with 5 public functions
- **Integration at 3 points**: sw-loop.sh (source + call + track), loop-iteration.sh (compose_prompt), dashboard (API endpoint)
- **15+ tests** covering matching, formatting, tracking, stats, and edge cases
- **3 concrete failure modes** analyzed with mitigations
- **Key design decision**: Separate library (not inline in sw-memory.sh) for testability and separation of concerns
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Failure Pattern Auto-Mitigation Engine with Memory-Driven Fix Injection
## Context
## Decision
### Core Design: Score → Rank → Format → Inject → Track
### Data Flow
### Error Handling
## Component Diagram
## Interface Contracts
### `scripts/lib/mitigation-engine.sh` — Public Functions
### Error Contracts
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 90,
      "summary": "Build stage failure patterns with proven mitigation rates (100% effective for 'cannot read property', 66% for 'reference error'). Directly applicable to auto-mitigation engine."
    },
    {
      "file": "success-patterns.json",
      "relevance": 85,
      "summary": "Recent successful patterns showing bug fix (3 iterations, npm test) with specific file patterns and test strategy. Provides baseline for what works in build loops."
    },
    {
      "file": "failures.json",
      "relevance": 82,
      "summary": "Test stage failures with root causes and specific fixes (sw-cleanup.sh stale detection, sed variable expansion). Patterns applicable to build iteration feedback."
    },
    {
      "file": "patterns.json",
      "relevance": 65,
      "summary": "Project metadata (Node.js, vitest, npm, CommonJS). Establishes project structure needed for build stage execution and test discovery."
    },
    {
      "file": "failures.json",
      "relevance": 60,
      "summary": "Simple failure signature (ENOENT) with npm install fix. Shows basic dependency-related failures that occur during build initialization."
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
- **memory-driven-remediation**: This skill directly addresses the core requirement: detecting failure patterns and safely auto-injecting proven fixes with guardrails to prevent cascading failures.
- **testing-strategy**: Build pattern matching with test-first approach—validate on known failure signatures, edge cases, and false-positive prevention before integrating into hot loop path.

## Memory-Driven Auto-Remediation Pattern

When building systems that detect failure patterns and auto-inject fixes, follow these principles:

### Pattern Matching Design
- **Signature specificity**: Extract error signatures with enough specificity to avoid false matches, but general enough to apply across similar contexts. Test both: what % of errors does the pattern match? Of matched errors, how many did the fix solve?
- **Semantic vs. regex**: Consider regex matching on error messages vs. semantic matching (stack trace structure, error type). Regex is faster but fragile; semantic is robust but adds latency. Measure both in staging.
- **Recency weighting**: Recent patterns (from last 100 builds) have higher priority than historical patterns; failure modes shift as code evolves.

### Fix Eligibility & Safety
- **Success threshold**: >80% is aggressive; validate in staging that false positives don't outweigh true fixes. Track precision (fix actually helped / injected count) separately from recall.
- **Context isolation**: A fix proven in context A (e.g., Node test failure) may not apply in context B (Python integration test). Store fix metadata: file patterns, failure types, test categories it applies to.
- **Injection safety**: Inject fix *suggestions* into loop context, not auto-apply to code. Let the agent decide whether to use it. Track agent acceptance rate separately from fix success rate.

### Metrics & Observability
- **Mitigation hit rate**: % of failures matched by patterns. High hit rate = good pattern coverage; low = incomplete patterns.
- **Success lift**: Actual success rate improvement. If baseline is 77%, measure whether mitigation engine drives it to 85%. Account for confounding factors (code quality improvements, env changes).
- **False positives**: Injected fixes that made things worse. Track separately; signal systemic issues with pattern matching or fix quality.
- **Pattern ROI**: Some patterns may match rarely; disable patterns with <5% hit rate after 100 builds to reduce noise.

### Failure Mode Recovery
- **Recursive loops**: If injected fix causes new failure matching another pattern, that fix could loop infinitely. Detect: track injected fix history per iteration, reject fixes if they cause regression.
- **Pattern conflicts**: If two patterns match, prioritize by recency and success rate. Document tie-breaking logic.
- **Graceful degradation**: If pattern matching hangs (malformed error-summary.json), timeout and continue without mitigation. Never block the loop.

### Testing Strategy
- Unit: pattern matching on synthetic error signatures (edge cases: truncated stack traces, locale-dependent messages, multiline errors).
- Integration: loop harness integration + fix injection context isolation.
- Scenario: recursive failures, conflicting patterns, fix causing new errors.
- Staging validation: run with both mitigation enabled and disabled, measure both success rate and false-positive rate.

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
"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-04-04T01:02:22Z
last_iteration_at: 2026-04-04T01:02:22Z
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

