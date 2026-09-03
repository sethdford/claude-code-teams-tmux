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
      "file": "success-patterns.json (test-repo-complexity)",
      "relevance": 70,
      "summary": "Low-complexity build stage pattern with single iteration, 300s duration, npm test strategy, and quick fix approach—directly applicable to the automated README comment task"
    },
    {
      "file": "success-patterns.json (test-repo-corrupt)",
      "relevance": 60,
      "summary": "Build stage patterns with low complexity, npm test, single iterations—two documented patterns provide precedent for quick build-stage fixes"
    },
    {
      "file": "index.json",
      "relevance": 50,
      "summary": "Build stage test failure pattern with timeout-related fix suggestion—helps prevent common test failures during build execution"
    },
    {
      "file": "success-patterns.json (test-repo)",
      "relevance": 45,
      "summary": "Iterative TDD approach with 5 iterations and module isolation pattern—informs development strategy if tests reveal issues during build"
    },
    {
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 40,
      "summary": "Build stage patterns for low-complexity tasks with npm test strategy—additional reference for quick-fix approaches"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 5 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Cross-repo memory pattern query surfaced in daemon triage scoring — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Cross-repo memory pattern query surfaced in daemon triage scoring

## Implementation Checklist
- [ ] **Task 1** — Add `triage.pattern_matching` block to `config/defaults.json`; verify `_config_get "triage.pattern_matching.similarity_threshold"` returns 60 from a scratch dir.
- [ ] **Task 2** — Implement `_triage_memory_dir()` and `_triage_pattern_enabled()` in `sw-triage.sh`. *(blocks 3, 5)*
- [ ] **Task 3** — Implement `_triage_tokenize()` with the stopword list. *(blocks 4)*
- [ ] **Task 4** — Implement `triage_score_pattern()` with the 70/20/10 weights and the zero-token guard. *(depends on 3; blocks 5)*
- [ ] **Task 5** — Implement `triage_match_known_pattern()` — local `failures.json` scan, then fleet `global.json` with the -10 penalty, threshold gate, `jq -n` output. *(depends on 2, 4; blocks 6, 7)*
- [ ] **Task 6** — Convert `cmd_analyze`'s output heredoc to `jq -n` and conditionally attach `known_pattern_match`; extend `emit_event`. *(depends on 5)*
- [ ] **Task 7** — Add the `pattern-match` subcommand to `main()` and `cmd_help`. *(depends on 5; blocks 8)*
- [ ] **Task 8** — Export `TRIAGE_PATTERN_MATCH` from `triage_score_issue()` in `scripts/lib/daemon-triage.sh`, leaving the integer stdout contract intact. *(depends on 7)*
- [ ] **Task 9** — Test: fixture builder in `sw-triage-test.sh` that writes a `failures.json` + `global.json` under `MEMORY_ROOT="$TEST_TEMP_DIR/mem/<hash>"` with a deterministic git-origin mock. *(blocks 10-13)*
- [ ] **Task 10** — Test: **match** case — issue text overlapping a local pattern yields `known_pattern_match.source == "local"` and `score >= 60`.
- [ ] **Task 11** — Test: **no-match** case — unrelated issue text emits no `known_pattern_match` key, and `keys_unsorted` equals today's exact key list (AC4 backward-compat pin).
- [ ] **Task 12** — Test: **fleet** cases — global-only pattern matches with `source == "fleet"` when `fleet_enabled=true`; produces no match when `SHIPWRIGHT_TRIAGE_PATTERN_MATCHING_FLEET_ENABLED=false`.
- [ ] **Task 13** — Test: **degradation** cases — missing memory dir, corrupt `failures.json` (`{`), empty `.failures[]`, and `enabled=false` each exit 0 with no match and no stderr noise.
- [ ] **Task 14** — Bump `VERSION` to 3.4.0; update `cmd_help`; add config docs to `.claude/CLAUDE.md`.
- [ ] **Task 15** — Run `bash scripts/sw-triage-test.sh`, `bash scripts/sw-lib-daemon-triage-test.sh`, `bash scripts/sw-daemon-test.sh`, and `shellcheck scripts/sw-triage.sh`; then `npm test`.
- [ ] `shipwright triage analyze <N>` emits `known_pattern_match` (with `pattern`, `source`, `score`, `confidence`, `note`) when a memory pattern scores at or above the threshold.
- [ ] No-match output is key-for-key identical to the pre-change output — pinned by an explicit `keys_unsorted` assertion (AC4).
- [ ] Local `failures.json` is consulted first; `global.json` only when `fleet_enabled`, and a local match beats an equal-scoring fleet match.
- [ ] Missing memory dir, missing `global.json`, corrupt JSON, absent `shasum`, and `enabled=false` all no-op with exit 0 (AC2).
- [ ] `triage_score_issue()` in `daemon-triage.sh` still prints only an integer; `sw-lib-daemon-triage-test.sh` and `sw-daemon-test.sh` pass unchanged (AC4).

## Context
- Pipeline: standard
- Branch: arch/cross-repo-memory-pattern-query-surfaced-3996
- Issue: #3996
- Generated: 2026-09-03T21:57:23Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: Verify the E2E test follows project conventions, uses proper fixtures/setup, and actually validates the README comment was added correctly rather than just asserting file changes.

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
started_at: 2026-09-03T22:39:36Z
last_iteration_at: 2026-09-03T22:39:36Z
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

