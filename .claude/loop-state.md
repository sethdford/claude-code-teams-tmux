---
goal: "Pre-Build Validation Gate with Fast-Fail Dependency Health Check

## Plan Summary
The plan is ready for your review. Here's a summary:

**What's being built:** A `pre_build_validate` stage (distinct from the existing post-deploy `validate`) that runs before `build` in all pipeline templates.

**6 checks it runs (all <30s total):**
1. Dependency manifest syntax — `package.json` / `requirements.txt` parseable, with line numbers in errors
2. Lock file integrity — presence + structure validation
3. Test command discoverability — runner binary exists in PATH
4. Lint check — optional, only if configured in package.json scripts
5. Git state — no merge conflicts, no conflict markers in source files
6. Required env vars — checked against `.env.required` if present

**Key design decisions:**
- Named `pre_build_validate` not `validate` to avoid collision with existing post-deploy smoke-test stage
- Implemented as a new `scripts/lib/pipeline-stages-prebuild.sh` module (no changes to execution engine)
- `--skip-validate` CLI flag + `SKIP_VALIDATE=true` env var for debugging
- `fail_on_dirty_worktree` defaults to `false` — daemon/worktree pipelines won't false-positive
- Enabled by default in standard/full/autonomous/deployed/cost-aware/enterprise; disabled in fast/hotfix

**Files:** 1 new stage module, 1 new test suite, 8 template updates, 3 lib file edits, 1 package.json update.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Pre-Build Validation Gate with Fast-Fail Dependency Health Check
## Context
## Decision
### Component decomposition (5 components, single-responsibility each)
### Interface contracts
### Error handling & boundaries
### Data flow
## Alternatives Considered
## Implementation Plan
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Pre-Build Validation Gate with Fast-Fail Dependency Health Check

### Goals
- New pipeline stage "validate" runs before "build" in all templates
- Validation checks: dependency manifest syntax, lock file integrity, test command existence, basic linting (if configured)
- Git state check: no merge conflicts, branch exists, worktree clean
- Environment check: required env vars present, API keys valid format
- Fast execution: <30 seconds for all checks
- Actionable error messages: "package.json has syntax error on line 14" not "validation failed"
- Skip validation with --skip-validate flag for debugging
- Emit structured validation report to .claude/pipeline-artifacts/pre-build-validation.json
- Dashboard shows validation failures distinctly from build failures
- **Priority**: P0

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json (first entry)",
      "relevance": 85,
      "summary": "Project conventions and structure (Node/vitest/CommonJS/src-test layout) directly inform what pre-build validation should check for dependencies and project health"
    },
    {
      "file": "knowledge.json",
      "relevance": 72,
      "summary": "Test failure patterns and fixes (mktemp issues, cleanup detection) inform what validation gates should detect as dependency/environment problems before build"
    },
    {
      "file": "failures.json (first entry)",
      "relevance": 68,
      "summary": "Recent test infrastructure failures show what can break in build pipelines, directly relevant to fast-fail dependency health checks"
    },
    {
      "file": "metrics.json (first entry)",
      "relevance": 65,
      "summary": "Build duration baseline (2089s) establishes performance expectations for pre-build validation to measure against"
    },
    {
      "file": "success-patterns.json (second entry with bug/feature patterns)",
      "relevance": 58,
      "summary": "Successful build patterns show iteration counts and test strategies that depend on healthy dependencies and pre-build validation"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Pre-Build Validation Gate with Fast-Fail Dependency Health Check — Resolution: 

## Skill Guidance (backend issue, AI-selected)
## API Design Expertise

Apply these API design patterns:

### RESTful Conventions
- Use nouns for resources, HTTP verbs for actions (GET /users, POST /users, DELETE /users/:id)
- Return appropriate status codes: 200 OK, 201 Created, 400 Bad Request, 404 Not Found, 422 Unprocessable
- Use consistent error response format: `{ "error": { "code": "...", "message": "..." } }`
- Version APIs when breaking changes are needed (/v1/users, /v2/users)

### Request/Response Design
- Accept and return JSON (Content-Type: application/json)
- Use camelCase for JSON field names
- Include pagination for list endpoints (limit, offset or cursor)
- Support filtering and sorting via query parameters

### Input Validation
- Validate ALL input at the API boundary — never trust client data
- Return specific validation errors with field names
- Sanitize strings against injection (SQL, XSS, command injection)
- Set reasonable size limits on request bodies

### Error Handling
- Never expose stack traces or internal errors to clients
- Log full error details server-side
- Use consistent error codes that clients can programmatically handle
- Include request-id in responses for debugging

### Authentication & Authorization
- Verify auth on EVERY endpoint (don't rely on frontend-only checks)
- Use principle of least privilege for authorization
- Validate tokens/sessions on each request
- Rate limit sensitive endpoints (login, password reset)

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Endpoint Specification**: For each endpoint: HTTP method, path, request body schema, response schema, success/error status codes
2. **Error Codes**: Complete list of all possible error responses with status code and error message format
3. **Rate Limiting**: If applicable, specify rate limit strategy (requests per minute, burst limits, throttle behavior)
4. **Versioning**: API version number and deprecation policy if breaking changes are possible

If any section is not applicable, explicitly state why it's skipped.
## Architecture Design Expertise

Create an Architecture Decision Record (ADR) that future developers can use as a map.

### Component Decomposition
- Identify the 3-5 key components this change touches
- Define clear boundaries — each component should have ONE reason to change
- Specify interfaces between components (function signatures, data contracts, event schemas)
- Dependencies should point inward — outer layers depend on inner, never the reverse

### Interface Contracts
- Define input/output types for every public function or API boundary
- Specify error contracts — what errors can each component return?
- Document preconditions and postconditions
- Use types to enforce invariants — make invalid states unrepresentable

### Design Decisions
For each non-obvious design decision, document:
1. **Context** — What constraint or requirement drives this?
2. **Decision** — What did you choose?
3. **Alternatives** — What else was considered? Why rejected?
4. **Consequences** — What trade-offs does this create?

### Patterns to Apply
- **Dependency Injection** — Don't hardcode dependencies, accept them as parameters
- **Single Responsibility** — Each module does one thing well
- **Open/Closed** — Extend through composition, not modification
- **Interface Segregation** — Don't force consumers to depend on methods they don't use

### Anti-Patterns to Flag
- God objects that know about everything
- Circular dependencies between modules
- Shared mutable state across components
- Leaky abstractions (implementation details in public interfaces)

### Testing Architecture
- How will each component be tested in isolation?
- What are the integration test boundaries?
- Which external dependencies need mocking?

### Required Output (Mandatory)
[... skills truncated: 8438→8000 chars ...]

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
"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-06-19T02:03:35Z
last_iteration_at: 2026-06-19T02:03:35Z
consecutive_failures: 0
total_commits: 2
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

