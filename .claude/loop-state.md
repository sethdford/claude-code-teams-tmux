---
goal: "E2E test: add comment to README [automated]

## Specification: E2E test: add comment to README [automated]

### Goals
- E2E test: add comment to README [automated]

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{"error":"memory_search_failed","results":[]}

Discoveries from other pipelines:
✓ Injected 13 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Pre-Build Diff-Size and Iteration-Velocity Anomaly Warning in Pipeline Vitals — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
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
- Generated: 2026-08-29T13:31:40Z

## Skill Guidance (backend issue, AI-selected)
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
iteration: 1
max_iterations: 3
status: error
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-08-29T15:00:19Z
last_iteration_at: 2026-08-29T15:00:19Z
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

