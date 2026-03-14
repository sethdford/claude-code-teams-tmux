---
goal: "Error Message Clarity Enhancement Pass for Top 5 Cryptic Errors

## Plan Summary
# Error Message Clarity Enhancement Pass — Implementation Plan

## Goal Summary

Transform 5 cryptic pipeline error messages into actionable debugging guides using a structured approach: **What Happened → Why It Happened → What To Do**. This improves DX by reducing debug time from hours to minutes.

---

## Root Cause Analysis (Systematic Debugging Phase 1-3)

### Evidence Collected: 5 Cryptic Errors from failures.json

1. **Missing --force Output Hint** (22 occurrences)
   - Current: `output missing: --force`
   - Script: `sw-cleanup.sh` line ~180
   - Root cause: Stale heartbeat detection doesn't display found items in dry-run mode
   - Evidence: Test expectation is for "Found N item(s)" with hint text

2. **Invalid JSON Output** (21 occurrences)
   - Current: `Invalid template errors correctly... ✓`
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Error Message Clarity Enhancement Pass for Top 5 Cryptic Errors
## Context
## Decision
### Error 1: Cleanup `--force` hint (sw-cleanup.sh:344)
### Error 2: Feedback JSON parsing (sw-feedback.sh:65-91)
### Error 3: mktemp parent directory (sw-outcome-feedback-test.sh:9-10)
### Error 4: Platform-specific `sed -i` (sw-code-review-test.sh:40)
### Error 5: sed expression quoting (multiple files)
## Alternatives Considered
## Implementation Plan
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Directly documents cryptic error patterns with root causes and fixes—examples include missing output hints, sed flag issues, and mktemp failures. Core resource for identifying which error messages need clarity improvements."
    },
    {
      "file": "patterns.json (first entry)",
      "relevance": 35,
      "summary": "Provides codebase structure context (Node, vitest, npm, JavaScript conventions). Useful for understanding where error messages live and how to test them, but not error-specific."
    },
    {
      "file": "patterns.json (second entry)",
      "relevance": 12,
      "summary": "Minimal project type detection metadata. Low signal for error message work—only confirms this is a Node project."
    },
    {
      "file": "patterns.json (third entry)",
      "relevance": 5,
      "summary": "Empty patterns list with cache metadata. No actionable content for error message enhancement."
    },
    {
      "file": "metrics.json",
      "relevance": 2,
      "summary": "Empty baselines object. Not relevant to error message clarity task."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Error Message Clarity Enhancement Pass for Top 5 Cryptic Errors — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Error Message Clarity Enhancement Pass for Top 5 Cryptic Errors

## Implementation Checklist
- [ ] 5 error messages enhanced with context, root cause, and next steps
- [ ] Before/after examples documented in a test suite
- [ ] All 102 test suites pass after enhancements
- [ ] Error messages appear correctly in failure scenarios
- [ ] No regression in script exit codes or side effects
- [ ] Task 1: Review error-message-clarity.md framework and extract template patterns
- [ ] Task 2: Read each of the 5 failing scripts to understand error context
- [ ] Task 3: Create test helper function to validate error messages appear correctly
- [ ] Task 4: Enhance sw-cleanup.sh --force output error (22 occurrences)
- [ ] Task 5: Enhance sw-feedback-test.sh JSON validation error (21 occurrences)
- [ ] Task 6: Enhance sw-hello-test.sh mktemp directory error (3 occurrences)
- [ ] Task 7: Enhance sw-code-review-test.sh sed -e flag error (2 occurrences)
- [ ] Task 8: Enhance sed quoting errors across test files (5 occurrences)
- [ ] Task 9: Run each affected test suite to confirm enhanced error messages appear
- [ ] Task 10: Run full test suite (npm test) to ensure no regressions
- [ ] Task 11: Document before/after examples for PR description
- [ ] All 5 error messages enhanced with three-part structure
- [ ] Enhanced messages preserve error codes for log parsing
- [ ] Enhanced messages fit in standard terminal width (80-100 chars)
- [ ] Each error message can be triggered in a test environment

## Context
- Pipeline: standard
- Branch: refactor/error-message-clarity-enhancement-pass-f-266
- Issue: #266
- Generated: 2026-03-14T21:21:00Z

## Skill Guidance (refactor issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **error-message-clarity**: Designing consistent, user-friendly error messages with root cause context and concrete next steps requires structured patterns—this skill provides the framework for that enhancement across multiple scripts.
- **testing-strategy**: Acceptance criteria requires test validation that new error messages appear in failure scenarios—need comprehensive test coverage including edge cases where cryptic errors currently occur.

## Error Message Clarity & Actionability Framework

Well-designed error messages cut debugging time in half. Poor ones waste hours. Use this framework to transform cryptic errors into user-friendly debugging guides.

### The Three-Part Structure

Every enhanced error message should clearly answer:

**1. What Happened (specific condition, not generic label)**
- ❌ Bad: "Build failed"
- ✅ Good: "Convergence detector timed out waiting for LOOP_COMPLETE signal after 45 minutes in iteration 12 at line 487 of sw-loop.sh"
- Include: specific failure point, timing, context values

**2. Why It Happened (root cause or common causes)**
- ✅ "This usually happens when: detector process crashed, or stage timeout was too short, or convergence stuck in infinite loop"
- List causes in order of likelihood
- Omit if cause is obvious from condition

**3. What To Do (concrete, testable next steps)**
- ✅ Step 1 (diagnosis): `ps aux | grep convergence-detector` — verify process is running
- ✅ Step 2 (state review): Check `.claude/pipeline-state.md` for last known iteration
- ✅ Step 3 (recovery): `shipwright pipeline resume` — continue from checkpoint
- Escalation: "If still stuck after step 3, see troubleshooting at [wiki-link]"

### Design Rules

**Clarity**
- Start with the specific failure, then zoom out
- Use exact file paths and line numbers when available
- Include variable values (timeout 45m, iteration 12, status code 137)
- Avoid jargon; explain technical terms on first use

**Actionability**
- Every error must have at least one concrete action
- Actions must be testable (not "debug further" or "investigate")
- Order by likelihood and diagnostic value, not alphabetically
- Distinguish diagnosis steps (to understand) from recovery steps (to fix)

**Consistency**
- Use the same format for related errors across all scripts
- Timeout errors always include: duration, what was being waited for, typical causes
- Missing file errors always include: expected path, how it should have been created, verification command
- Process exit errors always include: exit code, last log output, retry command

**Parseability**
- Preserve error codes/types for log aggregation: `ERROR_CODE=LOOP_TIMEOUT_45M`
- Keep structured markers in consistent positions so alerts still work
- Test that existing log parsing/alerting doesn't break

### Validation Checklist

Before merging enhanced error messages:
- [ ] Would someone unfamiliar with this code understand what went wrong?
- [ ] Can the user perform at least one suggested next step immediately?
- [ ] Does the error include enough state context (not overly verbose, not missing details)?
- [ ] Are similar errors across different scripts using the same pattern?
- [ ] Can your log aggregation/alerting systems still parse the error?
- [ ] Does the error pinpoint the failure (line number, function, condition) not just the symptom?

### Common Error Patterns & Templates

**Timeout Errors:**
```
Timeout: [process/operation] did not complete after [duration]
Likely cause: [most common reason], [secondary reason]
Diagnose: [check command]
Recover: [restart/resume command]
Details: Expected completion by [milestone], last progress [state]
```

**Missing File/Dependency:**
```
[File/dependency] not found at [path]
Expected here because: [setup step that should have created it]
Fix: [specific install command or setup step]
Verify: [command to confirm file exists and is valid]
```

**Process Crash/Exit:**
```
[Process] exited with code [N] (meaning: [interpretation])
Last output: [last 2-3 lines of relevant log]
Typically caused by: [list 2-3 most likely issues]
Check: [diagnostic command to see what went wrong]
Retry: [command to restart]
```

**Resource Constraint (OOM, disk, timeout):**
```
[Resource] exhausted: [metric reached limit]
Current state: [amount used], limit [max]
Usually because: [common cause], [secondary cause]
Fix: [increase limit or optimize usage], then retry
Monitor: [command to watch resource during next attempt]
```

### Real Examples from Shipwright

**Before**: "SCRIPT_DIR corruption breaking all pipeline runs" ← Cryptic, no action
**After**: "SCRIPT_DIR environment variable is empty or corrupted. This breaks all pipeline operations because scripts cannot locate themselves. Fix: Restart your shell or run `export SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)`. Verify: `echo $SCRIPT_DIR` should show the path to your scripts directory."

**Before**: "LOOP_COMPLETE signal not received" ← Missing context
**After**: "Convergence detector stopped but did not write LOOP_COMPLETE signal after 45 minutes. This happens when: (1) detector process crashed—check `ps aux | grep convergence`, (2) detector timed out waiting for convergence—review iterations in `.claude/pipeline-state.md`, or (3) signal file couldn't be written—check disk space. Next: `shipwright pipeline resume` to continue from checkpoint. If that fails, check pipeline-state.md for last error."

### Metrics to Track

Post-deployment, measure these DX improvements:
- Time from error message seen to problem fixed (should decrease)
- Support/debug questions about specific errors (should decrease)
- User success rate on first suggested action (should be >60%)
- Cases where users needed to read source code to understand error (should be ~0%)

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
started_at: 2026-03-14T21:26:08Z
last_iteration_at: 2026-03-14T21:26:08Z
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

