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
      "relevance": 95,
      "summary": "Documents E2E test failures including pipeline artifact writing, stale locks, and test infrastructure issues—directly applicable to understanding test stage challenges"
    },
    {
      "file": "metrics.json",
      "relevance": 70,
      "summary": "Baseline build duration (7095s) and test duration (1459s) provide performance expectations for the build stage"
    },
    {
      "file": "success-patterns.json",
      "relevance": 60,
      "summary": "Example of 3-iteration successful build using standard template and npm test, shows pattern for similar complexity work"
    },
    {
      "file": "knowledge.json",
      "relevance": 50,
      "summary": "Test infrastructure knowledge including mktemp failures and test setup patterns relevant to build environment"
    },
    {
      "file": "patterns.json",
      "relevance": 50,
      "summary": "Project context: Node/vitest/npm/commonjs—essential for understanding build and test requirements"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 9 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Adaptive Build-Loop Iteration Budget from Historical Outcomes — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Adaptive Build-Loop Iteration Budget from Historical Outcomes

## Implementation Checklist
- [ ] **T1** — Compute `ADAPTIVE_COHORT` unconditionally in `apply_adaptive_budget()`; keep budget application behind the opt-in guard
- [ ] **T2** — Add `cohort=` to the `loop.iteration_complete` emission *(depends on T1)*
- [ ] **T3** — Rewrite `_iter_samples_for_cohort()`: single `jq -R --arg` pass, `fromjson?`, `tail` bounds
- [ ] **T4** — Rewrite `_iter_samples_global()`: same single-pass shape + `fromjson?` guard + scan bound
- [ ] **T5** — Add `ITERATIONS_SCAN_LINES`; wire `ITERATIONS_LOOKBACK` *(depends on T3, T4)*
- [ ] **T6** — Replace hardcoded 5/3 with named constants; delete unused threshold constants and `SC2034` disables
- [ ] **T7** — Add `ADAPTIVE_TIER` / `ADAPTIVE_SAMPLES` globals to `adaptive_iterations_suggest()` *(depends on T6)*
- [ ] **T8** — Extend `loop.budget_selected` emission with `tier` + `sample_count` *(depends on T7)*
- [ ] **T9** — Update `config/event-schema.json`; run `sw-event-schema-sync.sh` to confirm zero drift *(depends on T2, T8)*
- [ ] **T10** — Add cohort round-trip test (emit → read back, proving G1 fixed) *(depends on T2)*
- [ ] **T11** — Add adversarial-label test: labels with `"`, `\`, `$`, backtick *(depends on T3)*
- [ ] **T12** — Add lookback-bound test: 10k-line events file, assert bounded samples + runtime < 5s *(depends on T5)*
- [ ] **T13** — Register test suite in `package.json` `test:legacy-chain`
- [ ] **T14** — Update `.claude/CLAUDE.md` (Loop Configuration table + `AUTO:test-suites`)
- [ ] **T15** — Run `shellcheck` on both changed scripts; run `sw-adaptive-iterations-test.sh` + `sw-loop-test.sh`
- [ ] `loop.iteration_complete` carries a `cohort` field; a fresh loop run's events are consumable by `_iter_samples_for_cohort` (**G1 closed, proven by T10**)
- [ ] No jq program is built by string interpolation anywhere in `adaptive-iterations.sh`; all values pass via `--arg` (**G2 closed**)
- [ ] `_iter_samples_for_cohort` and `_iter_samples_global` each spawn exactly one `jq`; a 10k-line events file resolves in < 5s (**G3 closed**)
- [ ] `scripts/sw-adaptive-iterations-test.sh` runs in `npm test` via `test:legacy-chain` (**G4 closed**)
- [ ] Test suite passes with **0 failures** and ≥ 38 assertions, including cohort round-trip, adversarial-label, and lookback-bound cases

## Context
- Pipeline: standard
- Branch: feat/adaptive-build-loop-iteration-budget-fro-1502
- Issue: #1502
- Generated: 2026-08-08T02:38:06Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **e2e-test-automation**: This skill directly addresses the core requirement: file-modifying E2E tests must use worktrees or isolated temp directories to prevent test artifacts from polluting the main working tree.

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
iteration: 1
max_iterations: 3
status: error
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-08-08T03:29:26Z
last_iteration_at: 2026-08-08T03:29:26Z
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

