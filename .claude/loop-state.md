---
goal: "Success Pattern Library with Automatic Pattern Replay Engine

## Plan Summary
## Implementation Plan: Success Pattern Library (#338)

The branch already has substantial scaffolding from previous commits. Here's a summary of what needs to be completed:

### What's Already Done
- `scripts/lib/success-patterns.sh` — all capture, match, A/B testing, export functions
- Pattern capture wired into `memory_finalize_pipeline()` (success-only)  
- Pattern inject called in the build stage via `memory_inject_context`
- `sw-success-patterns-test.sh` — 481-line test suite

### Three Critical Gaps to Close

**1. `success_pattern_inject()` silently discards its output** (`lib/success-patterns.sh:302`)
The rich `jq` formatting block pipes to `>> /dev/null`. Fallback loop iterates a JSON array as plain text (broken). Fix: output formatted patterns to stdout properly.

**2. Missing dashboard section** (`sw-memory.sh:1545`)
`memory_show` has PROJECT, FAILURE PATTERNS, DECISIONS, BASELINES — no SUCCESS PATTERNS. Add it.

**3. No REST endpoint** (`dashboard/server.ts`)
`GET /api/memory/success-patterns` doesn't exist. Add it.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Success Pattern Library with Automatic Pattern Replay Engine
## Context
## Decision
### Component Architecture
### Interface Contracts
### Data Flow
### Critical Bug Fixes
# Fallback loop reads entire JSON blob as one line — broken
### Recency Scoring Enhancement
### Repo Export
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "success-patterns.json (first entry)",
      "relevance": 95,
      "summary": "Contains fully-formed success pattern examples with complete metadata structure (id, goal, complexity, iterations, duration_s, files_changed, file_patterns, test_strategy, cost_usd, injection tracking). This is the exact data model needed for the Success Pattern Library."
    },
    {
      "file": "failures.json (first entry)",
      "relevance": 75,
      "summary": "Documents failure patterns with root causes and fixes from recent builds (sw-cleanup.sh, sed command issues). Understanding failure modes helps the pattern library provide better replay guidance and avoid regressions."
    },
    {
      "file": "patterns.json (first entry)",
      "relevance": 70,
      "summary": "Contains project conventions (source_dir, test_pattern, import_style, test_runner: vitest, package_manager: npm) and detected project type. Contextual info for understanding what patterns apply to this Node.js/vitest environment."
    },
    {
      "file": "success-patterns.json (second entry)",
      "relevance": 60,
      "summary": "Additional success pattern example with similar metadata structure, though less detailed than the first entry. Shows pattern library should handle patterns across different goal types (bug, feature)."
    },
    {
      "file": "failures.json (second/fourth entry)",
      "relevance": 50,
      "summary": "Documents common build-stage failures (undefined variables, scope issues) with 100% fix effectiveness. Patterns for these errors could be captured and replayed in the library."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Success Pattern Library with Automatic Pattern Replay Engine — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Success Pattern Library with Automatic Pattern Replay Engine

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/success-patterns.sh` with capture, match, inject, export functions
- [ ] Task 2: Add A/B testing functions (assign, record, report) to success-patterns.sh
- [ ] Task 3: Source the module in `scripts/sw-memory.sh` and hook into `memory_finalize_pipeline()`
- [ ] Task 4: Add success pattern section to `memory_inject_context("build")` in sw-memory.sh
- [ ] Task 5: Add success pattern injection to prompt composition in `scripts/lib/loop-iteration.sh`
- [ ] Task 6: Pass additional metadata in `scripts/lib/pipeline-commands.sh` success path
- [ ] Task 7: Add `/api/success-patterns` endpoints to `dashboard/server.ts`
- [ ] Task 8: Add `fetchSuccessPatterns` to `dashboard/src/core/api.ts` and types to `api.ts`
- [ ] Task 9: Add Success Patterns section to `dashboard/src/views/insights.ts`
- [ ] Task 10: Create `scripts/sw-success-patterns-test.sh` test suite
- [ ] Task 11: Register test suite in `package.json`
- [ ] Task 12: Run full test suite to verify no regressions
- [x] No secrets in code
- [x] No user input executed as code
- [x] File paths validated (no directory traversal — uses `repo_memory_dir()`)
- [x] JSON built via jq --arg (injection-safe)
- [x] File permissions inherit from ~/.shipwright/ directory

## Context
- Pipeline: standard
- Branch: feat/success-pattern-library-with-automatic-p-338
- Issue: #338
- Generated: 2026-04-03T18:32:45Z

## Skill Guidance (backend issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: Pattern capture and injection are high-stakes; tests must verify patterns are correctly extracted, indexed, injected into prompts, and don't malform agent input.
- **observability**: Dashboard requires real-time pattern metrics (capture rate, library size, top patterns by type, A/B arm distribution); pattern injection must emit structured logs for later analysis.
- **success-pattern-lifecycle**: Governs how patterns are captured, versioned, expire over time, and audit-trailed—ensures stale patterns don't hurt future builds and library stays maintainable.

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

## Observability: Watch the Deploy Like a Hawk

Post-deploy monitoring catches what tests miss. Real traffic reveals real problems.

### What to Monitor (by Priority)

**P0 — Immediate (first 5 minutes):**
- Error rate: any increase over baseline?
- Health check: still returning 200?
- Latency: p50/p95/p99 within normal range?
- Memory/CPU: any sudden spikes?

**P1 — Short-term (5-30 minutes):**
- Business metrics: are users completing key flows?
- Queue depths: are background jobs processing normally?
- Connection pools: any exhaustion or leak patterns?
- Disk usage: any unexpected growth?

**P2 — Medium-term (1-24 hours):**
- Memory trends: gradual leak over time?
- Error rate trends: slowly increasing?
- User-reported issues: any new support tickets?
- Performance degradation under sustained load?

### Anomaly Detection Patterns
- **Spike detection**: >2x baseline error rate in any 1-minute window
- **Trend detection**: steadily increasing error rate over 5-minute window
- **Absence detection**: expected periodic events stop occurring
[... skills truncated: 9166→8000 chars ...]
- Response status code distribution (2xx vs 4xx vs 5xx)
- Request throughput — drops indicate client-side breakage
- Authentication failures — spikes indicate auth regression

**Database changes:**
- Query latency per endpoint
- Connection pool utilization
- Slow query log entries
- Replication lag (if applicable)

### Incident Escalation
If monitoring detects issues:
1. Execute rollback (if auto-rollback enabled)
2. Create incident issue with monitoring data
3. Attach relevant logs and metrics
4. Tag the original issue with `incident` label
5. Do NOT silence alerts — let them fire

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Monitoring Checklist**: P0/P1/P2 metrics to watch (error rate, latency, memory, health checks) with specific thresholds
2. **Anomaly Detection Triggers**: Explicit conditions that trigger alerts (spike detection >2x, trend detection over 5min, absence detection, latency shift >50%)
3. **Log Analysis**: Search strategy for new ERROR/FATAL entries, stack traces, retry storms, resource exhaustion patterns
4. **Auto-Rollback Decision Criteria**: Conditions that trigger automatic rollback (health check failures, error rate threshold, critical dependency unreachable, memory exhaustion)

If any section is not applicable, explicitly state why it's skipped.

## Success Pattern Lifecycle Management

### Pattern Capture
When a pipeline succeeds, extract and store a canonical pattern snapshot:
- **Approach**: Brief description of strategy taken (e.g., 'iterative refactoring with incremental tests')
- **Iteration count**: How many build loop iterations to success
- **File patterns**: Changed file paths grouped by semantic role (tests, impl, docs)
- **Test strategy**: Which tests drove the build (unit, integration, e2e suite composition)
- **Commit structure**: Atomic commits vs squashed, message pattern (imperative vs descriptive)
- **Model/effort**: Claude model used, effort level setting
- **Duration**: Total time from intake to success
- **Metadata**: Issue type, complexity score, codebase domain (frontend/backend/infra)

### Indexing & Storage
- Store patterns in `.claude/memory/<repo-hash>/success-patterns.json` as an array of pattern objects
- Index by (issue_type, complexity_band, codebase_domain) for O(1) retrieval
- Maintain a secondary index: (pattern_hash) → timestamp for deduplication
- Keep a rolling window of 200 patterns per repo (rotate by LRU, preserve high-value patterns)

### Pattern Versioning
- Capture pattern_version=YYYYMMDD_SEQUENCE at capture time
- Include codebase_snapshot: git commit SHA when pattern was captured
- When querying patterns for injection, filter by age: prefer patterns < 90 days old, warn if pattern is stale
- Allowlist mechanism: certain patterns (golden paths) are marked keep_forever=true

### Pattern Expiration & Cleanup
- Patterns older than 180 days are automatically archived (not deleted; moved to `.claude/memory/<repo>/archive/`)
- Patterns matching failed builds within 7 days are demoted (success_weight -= 1, min 0)
- Patterns from refactored/deleted code paths are invalidated via `git log --follow` on files in the pattern

### Audit Trail
- Each pattern capture logs: (pattern_id, issue_id, timestamp, success_build_sha, injected_count_since_capture)
- Audit log stored in `.claude/memory/<repo-hash>/pattern-audit.jsonl`
- Monthly archival: compress audit logs older than 60 days to `.claude/memory/<repo-hash>/archive/audit-YYYY-MM.jsonl.gz`

### Injection Safety
- Validate pattern before injection: ensure all fields are JSON-safe, no embedded nulls, description < 200 chars
- If validation fails, log to error-log.jsonl and skip injection (don't fail the build)
- Pattern injection is read-only: patterns are never modified during injection, only metadata updated

### Monitoring & Quality
- Dashboard metric: pattern_reuse_rate = (builds_with_injection) / (total_builds)
- Dashboard metric: pattern_success_delta = (success_rate_with_injection) - (success_rate_baseline)
- Metric: stale_pattern_ratio = (patterns > 120 days old) / (total patterns)
- Alert if stale_pattern_ratio > 0.3 (indicates insufficient pattern refresh)

### API
- `capture_pattern(approach, iteration_count, files_changed, test_strategy, commits, metadata)` → pattern_id
- `query_patterns(issue_type, complexity_band, limit=3)` → [pattern1, pattern2, ...]
- `inject_pattern(pattern_id, build_prompt) → enriched_prompt
- `invalidate_pattern(pattern_id, reason)` (soft-delete)
- `pattern_audit_log(pattern_id)` → [(issue_id, timestamp, result), ...]


## Failure Diagnosis (Iteration 2)
Classification: unknown
Strategy: retry_with_context
Repeat count: 0

## Failure Diagnosis (Iteration 3)
Classification: unknown
Strategy: retry_with_context
Repeat count: 1

## Failure Diagnosis (Iteration 4)
Classification: unknown
Strategy: alternative_approach
Repeat count: 2
INSTRUCTION: This error has occurred 2 times. The previous approach is not working. Try a FUNDAMENTALLY DIFFERENT approach:
- If you were modifying existing code, try rewriting the function from scratch
- If you were using one library, try a different one
- If you were adding to a file, try creating a new file instead
- Step back and reconsider the requirements

## Failure Diagnosis (Iteration 5)
Classification: unknown
Strategy: alternative_approach
Repeat count: 3
INSTRUCTION: This error has occurred 3 times. The previous approach is not working. Try a FUNDAMENTALLY DIFFERENT approach:
- If you were modifying existing code, try rewriting the function from scratch
- If you were using one library, try a different one
- If you were adding to a file, try creating a new file instead
- Step back and reconsider the requirements"
iteration: 5
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-04-04T01:36:59Z
last_iteration_at: 2026-04-04T01:36:59Z
consecutive_failures: 0
total_commits: 4
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-04-04T01:06:26Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":525318,"duration_api_ms":472689,"num_turns":61,"resu

### Iteration 2 (2026-04-04T01:15:57Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":530875,"duration_api_ms":411845,"num_turns":63,"resu

### Iteration 3 (2026-04-04T01:19:51Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":192394,"duration_api_ms":138785,"num_turns":20,"resu

### Iteration 4 (2026-04-04T01:34:14Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":624477,"duration_api_ms":231734,"num_turns":29,"resu

