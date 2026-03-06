---
goal: "sw-pipeline.sh Modular Decomposition - Extract Stage Execution Library

## Plan Summary
# Implementation Plan: sw-pipeline.sh Modular Decomposition — Extract Stage Execution Library

## Status Summary

**Key Finding**: All 12 stage execution functions (`stage_intake`, `stage_plan`, `stage_build`, etc.) are **already fully extracted** into `scripts/lib/pipeline-stages-*.sh` modules. The dispatch mechanism (`run_stage_with_retry`) uses dynamic function calls (`stage_${id}`) — no inline stage logic remains.

**The actual problem**: sw-pipeline.sh is still **3,026 lines** (target: <1,500) because it contains:
- Helper/utility functions (~700 lines): coverage parsing, cost estimation, duration formatting, error classification, notifications
- Self-healing build-test loop (~306 lines): convergence detection, memory injection, adaptive iteration limits
- Pipeline lifecycle (~600 lines): `pipeline_start`, post-completion cleanup, worktree management, dry run
- Pipeline status/abort/list/show subcommands (~250 lines)
- Orchestration core (`run_pipeline` + `run_stage_with_retry`): ~550 lines — this stays

## Brainstorming: Design Decisions

### Requirements Clarity
- **Minimum viable change**: Extract ~1,500+ lines of non-orchestration code into 3 new library files
- **Implicit requirement**: Existing tests must pass without modification — the extraction must be purely structural
- **Acceptance criteria**: sw-pipeline.sh < 1,500 lines, new unit tests for extracted functions, no performance regression
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: sw-pipeline.sh Modular Decomposition - Extract Stage Execution Library
## Context
## Decision
### 1. `scripts/lib/pipeline-utils.sh` (~500 lines)
### 2. `scripts/lib/pipeline-execution.sh` (~470 lines)
### 3. `scripts/lib/pipeline-lifecycle.sh` (~600 lines)
### Source order in `sw-pipeline.sh`
# Existing libs (unchanged)
# New libs (added in dependency order)
### What stays in `sw-pipeline.sh` (~1,200-1,400 lines)
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 95,
      "summary": "Detailed conventions captured 2026-03-06: source_dir=src/, test_pattern=*.test.js, vitest runner, npm, commonjs imports - directly guides where to place extracted stage execution library and test structure"
    },
    {
      "file": "patterns.json",
      "relevance": 35,
      "summary": "Minimal entry from 2026-02-21: confirms Node.js type but superseded by more recent detailed patterns entry with full conventions"
    },
    {
      "file": "failures.json",
      "relevance": 30,
      "summary": "Empty failures list - indicates clean slate for build stage; provides baseline for tracking any issues during library extraction"
    },
    {
      "file": "decisions.json",
      "relevance": 20,
      "summary": "Empty - no architectural decisions recorded yet; relevant category for capturing modular decomposition design choices during this build"
    },
    {
      "file": "metrics.json",
      "relevance": 15,
      "summary": "Empty baselines - would help track build performance impact of extracted library but no prior data available"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for sw-pipeline.sh Modular Decomposition - Extract Stage Execution Library — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — sw-pipeline.sh Modular Decomposition - Extract Stage Execution Library

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/pipeline-utils.sh` — extract utility functions (coverage, cost, duration, error classification, notifications)
- [ ] Task 2: Create `scripts/lib/pipeline-execution.sh` — extract retry logic, self-healing loop, auto-rebase
- [ ] Task 3: Create `scripts/lib/pipeline-lifecycle.sh` — extract all pipeline subcommands and lifecycle management
- [ ] Task 4: Update `scripts/sw-pipeline.sh` — remove extracted code, add source lines, verify <1,500 lines
- [ ] Task 5: Run existing test suite to verify no regressions
- [ ] Task 6: Create `scripts/sw-lib-pipeline-utils-test.sh` — unit tests for utility functions
- [ ] Task 7: Create `scripts/sw-lib-pipeline-execution-test.sh` — unit tests for execution logic
- [ ] Task 8: Create `scripts/sw-lib-pipeline-lifecycle-test.sh` — unit tests for lifecycle functions
- [ ] Task 9: Register new test suites in `package.json`
- [ ] Task 10: Run full test suite and fix any issues
- [ ] Task 11: Update CLAUDE.md documentation with new library entries
- [ ] `scripts/sw-pipeline.sh` is under 1,500 lines
- [ ] All 3 new library files exist with include guards and correct function signatures
- [ ] `npm test` passes with zero regressions (all existing 102+ test suites pass)
- [ ] New unit test suites exist for each extracted library
- [ ] Each extracted function is independently testable by sourcing its library file
- [ ] CLAUDE.md Shared Libraries table updated with new files
- [ ] No functional change — pipeline behavior is identical before and after

## Context
- Pipeline: standard
- Branch: refactor/sw-pipeline-sh-modular-decomposition-ext-189
- Issue: #189
- Generated: 2026-03-06T06:33:10Z

## Skill Guidance (refactor issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: Design unit test strategy for extracted stage functions in isolation, verify all error paths are testable, ensure mock/real pipeline state can be injected cleanly.
- **security-audit**: Ensure extracted stage functions don't inadvertently expose internal state, allow unintended transitions, or create new injection vectors when called as independent functions.

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

## Security Audit Expertise

Apply OWASP Top 10 and security best practices:

### Injection Prevention
- Use parameterized queries for ALL database access
- Sanitize user input before rendering in HTML/templates
- Validate and sanitize file paths — prevent directory traversal
- Never execute user-supplied strings as code or commands

### Authentication
- Hash passwords with bcrypt/argon2 (never MD5/SHA1)
- Implement account lockout after failed attempts
- Use secure session management (HttpOnly, Secure, SameSite cookies)
- Require re-authentication for sensitive operations

### Authorization
- Check permissions server-side on EVERY request
- Use deny-by-default — explicitly grant access
- Verify resource ownership (user can only access their own data)
- Log authorization failures for monitoring

### Data Protection
- Never log sensitive data (passwords, tokens, PII)
- Encrypt sensitive data at rest
- Use HTTPS for all communications
- Set appropriate CORS headers — never use wildcard in production

### Secrets Management
- Never hardcode secrets in source code
- Use environment variables or secret managers
- Rotate secrets regularly
- Check for accidentally committed secrets (API keys, passwords, tokens)

### Dependency Security
- Check for known vulnerabilities in dependencies
- Pin dependency versions to prevent supply chain attacks
- Review new dependencies before adding them

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Threat Model (STRIDE)**: Identify threats across Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege
2. **Auth Flow**: Step-by-step diagram of authentication/authorization flow with session/token handling
3. **Input Validation Points**: List all places where user input enters the system and how each is validated/sanitized
4. **Security Checklist**: Items verified (no secrets in code, secrets rotated, HTTPS enforced, CORS configured, rate limiting applied)

If any section is not applicable, explicitly state why it's skipped.


## Failure Diagnosis (Iteration 2)
Classification: unknown
Strategy: retry_with_context
Repeat count: 0"
iteration: 2
max_iterations: 30
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-06T07:35:01Z
last_iteration_at: 2026-03-06T07:35:01Z
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
### Iteration 1 (2026-03-06T07:04:57Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":1332025,"duration_api_ms":1204969,"num_turns":112,"r

