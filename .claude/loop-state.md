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
      "file": "patterns.json",
      "relevance": 60,
      "summary": "Project conventions: node type, vitest test runner, commonjs imports — essential context for building E2E test implementation"
    },
    {
      "file": "metrics.json",
      "relevance": 50,
      "summary": "Historical baselines: build_duration_s=7095, test_duration_s=1459 — useful for setting expectations and detecting anomalies in current build"
    },
    {
      "file": "failures.json",
      "relevance": 40,
      "summary": "Pipeline E2E test patterns: artifact generation issues, test setup pitfalls, stale pipeline locks — relevant failure modes to avoid"
    },
    {
      "file": "success-patterns.json",
      "relevance": 35,
      "summary": "Similar complexity patterns (complexity 60-65): 3 iterations, standard template, npm test strategy — applicable success model for this build"
    },
    {
      "file": "knowledge.json",
      "relevance": 25,
      "summary": "Test infrastructure patterns: mktemp failures, cleanup output format, schema validation — general knowledge applicable to test reliability"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 5 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Detect Divergent Build-Loop Failures and Terminate Early — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Detect Divergent Build-Loop Failures and Terminate Early

## Implementation Checklist
- [ ] Task 1: Extract `_progress_insertions()` from `check_progress` in `loop-convergence.sh` (identical semantics)
- [ ] Task 2: Implement `_divergence_hash()` with normalization + `shasum`/`sha256sum`/`cksum` fallback chain
- [ ] Task 3: Implement `record_divergence_sample()` (append-only tracking, counter increment/reset)
- [ ] Task 4: Implement `check_divergence()` + `_divergence_reset()`, writing `divergence.json` atomically and emitting `loop.divergence_detected`
- [ ] Task 5: Wire config vars, `--divergence-threshold` / `--no-divergence` flags, and help text into `sw-loop.sh`
- [ ] Task 6: Call `check_divergence` before `check_circuit_breaker`; call `record_divergence_sample` after `check_progress`; reset at loop init and on session restart
- [ ] Task 7: Add the `divergent_failure` arm to the `show_summary` status table
- [ ] Task 8: Register `loop.divergence_detected` in `config/event-schema.json`; verify with `sw-event-schema-sync.sh`
- [ ] Task 9: Classify divergence in `pipeline-stages-build.sh` → `failure-reason.txt`, ahead of the context-exhaustion sniff
- [ ] Task 10: Add the `divergent_failure` class + retry budget to `daemon-failure.sh`
- [ ] Task 11: Surface divergent aborts in `shipwright cost show` (text + `--json`)
- [ ] Task 12: Surface divergent aborts in `shipwright daemon metrics` (text + `--json`)
- [ ] Task 13: Add 11 divergence assertions to `scripts/sw-loop-test.sh`
- [ ] Task 14: Update `.claude/CLAUDE.md` Loop Configuration table and abort-reason docs
- [ ] Task 15: Run `bash -n` + shellcheck on touched scripts and the full `npm test` suite; confirm zero regressions
- [ ] `sw-loop.sh` tracks an `error-summary.json` signature hash **and** changed-line count for every iteration, persisted to `$LOG_DIR/divergence-agent-N.txt`
- [ ] The loop aborts with `STATUS="divergent_failure"` — distinct from `circuit_breaker` — when the signature repeats `loop.divergence_threshold` times (default 3) with insertions ≤ `loop.divergence_progress_lines` (default 2)
- [ ] `loop.divergence_detected` is emitted, registered in `config/event-schema.json`, and `sw-event-schema-sync.sh` reports no drift
- [ ] `divergence.json` is written atomically (tmp + `mv`, `jq --arg`) and consumed by `pipeline-stages-build.sh` → `failure-reason.txt=divergent_failure`
- [ ] `classify_failure` returns `divergent_failure` (not `context_exhaustion`) for a divergent run, with its own retry budget

## Context
- Pipeline: standard
- Branch: ci/detect-divergent-build-loop-failures-and-1582
- Issue: #1582
- Generated: 2026-08-08T02:37:39Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: E2E tests for automated README modification need clear isolation strategies (temp branches vs. live README), idempotency guarantees for re-running, and specific assertions that detect real failures like encoding issues or malformed content.

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
max_iterations: 3
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-08-08T03:16:22Z
last_iteration_at: 2026-08-08T03:16:22Z
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

