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
      "file": "failures.json",
      "relevance": 92,
      "summary": "Contains E2E test failures about pipeline artifacts (plan.md/review.md) not being written to .claude/pipeline-artifacts/, and test execution issues (mktemp, stale locks). Directly applicable to an E2E test build stage."
    },
    {
      "file": "patterns.json",
      "relevance": 88,
      "summary": "Project conventions (vitest test runner, npm package manager, src/ directory, commonjs imports) are essential for understanding how to build and execute tests in this Node.js project during the build stage."
    },
    {
      "file": "metrics.json",
      "relevance": 72,
      "summary": "Baseline metrics show build_duration_s=7095 and test_duration_s=1459, providing context for expected stage timings and iteration limits in the build loop."
    },
    {
      "file": "success-patterns.json",
      "relevance": 65,
      "summary": "Contains successful build patterns (complexity 60-65, standard template, npm test strategy, 3 iterations) that align with the current goal's scope and provide proven approaches for similar E2E/test scenarios."
    },
    {
      "file": "knowledge.json",
      "relevance": 48,
      "summary": "Documents test-specific failure patterns (mktemp directory issues, cleanup/heartbeat detection) and proven fixes that could prevent common test execution blockers during the build stage."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 11 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Adaptive Build-Loop Iteration Budget from Historical Outcomes — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Adaptive Build-Loop Iteration Budget from Historical Outcomes

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/adaptive-iterations.sh` — load guard, `VERSION=3.3.0`, tunables
- [ ] Task 2: Implement `adaptive_iterations_cohort` (bash 3.2 safe, always returns a key)
- [ ] Task 3: Implement `_iter_samples_for_cohort` with `fromjson? // empty` malformed-line tolerance
- [ ] Task 4: Implement `_iter_samples_global` (job_id group-by over `loop.iteration_complete`)
- [ ] Task 5: Implement `_iter_percentile` in awk (no `sort` pipeline)
- [ ] Task 6: Implement `adaptive_iterations_suggest` — 3-tier fallback + asymmetric clamping
- [ ] Task 7: Implement `adaptive_iterations_record_outcome` + `adaptive_iterations_explain`
- [ ] Task 8: Wire into `sw-loop.sh` — source, `--adaptive-iterations` flag, `apply_adaptive_budget()` hook, outcome emit, help text
- [ ] Task 9: Write `scripts/sw-adaptive-iterations-test.sh` (18 unit tests, table below)
- [ ] Task 10: Add flag-exists + default-off assertions to `sw-loop-test.sh`
- [ ] Task 11: Regenerate `config/event-schema.json` via `sw-event-schema-sync.sh --write`
- [ ] Task 12: Document in `.claude/CLAUDE.md` (config table + cold-start caveat)
- [ ] Task 13: Run new suite + `sw-loop-test.sh` + full `npm test`
- [ ] Task 14: `shellcheck` clean; `shipwright version check` passes
- [ ] `adaptive_iterations_suggest` returns a history-derived budget for a well-sampled cohort and the unmodified static default when history is absent, empty, malformed, or under-sampled — **AC #1**
- [ ] `shipwright loop --adaptive-iterations` enables it; `loop.adaptive_iterations` in `daemon-config.json` enables it; **default is off** and `git diff` shows no behavior change on any existing path when unset — **AC #2**
- [ ] All 18 unit tests pass, covering no-history fallback, sufficient-history adjustment, and malformed/missing file degradation — **AC #3**
- [ ] `loop.budget_selected` (cohort, budget, default, source tier, sample count) and `loop.budget_outcome` (cohort, iterations, converged, budget) appear in `events.jsonl` and are registered in `config/event-schema.json` — **AC #4**
- [ ] `--max-iterations N` given explicitly still wins — `MAX_ITERATIONS_EXPLICIT` honored
- [ ] `npm test` green (all auto-discovered suites); `shellcheck` clean; bash 3.2 constructs only

## Context
- Pipeline: standard
- Branch: feat/adaptive-build-loop-iteration-budget-fro-1502
- Issue: #1502
- Generated: 2026-08-07T18:39:44Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **e2e-test-automation**: Critical for this file-modifying test—enforce worktree or isolated temp directory usage to prevent working tree pollution and ensure test isolation.

## E2E Test Automation for File Modification

### Test Isolation & Git State
File-modifying E2E tests must use worktrees or isolated temp directories to avoid polluting the main working tree. Always:
- Create a fresh worktree or temp directory per test run
- Verify git state is clean before starting
- Use `git reset --hard` or cleanup hooks to restore state after test completion
- Never rely on test execution order for cleanup

### Idempotency & Repeatability
- Run the test twice in succession; both runs must succeed with identical results
- If your test modifies a file, the second run must detect that modification and either skip or validate existing state
- Avoid hardcoding line numbers or positions—use markers (`<!-- AUTO:section-id -->`) to find insertion points

### Assertion Patterns
- Assert on file *content* (use `grep` or content comparison), not just file *existence*
- Verify git diff output to confirm the modification is what you expected
- Check that git can track the change (no binary files, encoding issues, or CRLF conflicts)

### Failure Diagnosis
- Log the full `git status`, `git diff`, and file content on assertion failure
- Capture the diff so reviewers can see exactly what was supposed to change
- If cleanup fails, fail the test loudly—don't silently leave state behind

### README-Specific Patterns
When testing README modifications:
- Preserve existing content and comments; only add new sections or markers
- Use HTML comment markers (`<!-- AUTO:section -->`) to delineate auto-managed sections
- Validate markdown syntax after modification (check for broken links, mismatched brackets)
- Test both initial addition and update scenarios (section doesn't exist vs. already exists)
"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-08-07T20:21:39Z
last_iteration_at: 2026-08-07T20:21:39Z
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

