---
goal: "Installation and Setup Telemetry with Automatic Recovery Checkpoint System

## Plan Summary
Now I have a complete picture. Let me create the implementation plan.

---

# Implementation Plan: Installation and Setup Telemetry with Automatic Recovery Checkpoint System

## Brainstorming: Design Decisions

### Requirements Clarity
- **Minimum viable change**: Instrument the 14 steps in `sw-init.sh` (the core engine) with timing + checkpoint saves, add `--resume` to skip completed steps, and integrate doctor.
- **Implicit requirements**: The checkpoint must handle partial failures within a step (e.g., TPM clone succeeds but plugin install fails). Flags passed to the original run must be preserved for resume.
- **Acceptance criteria**: Defined in issue — telemetry per step, checkpoint file, `--resume`, events.jsonl logging, doctor integration.

### Alternatives Considered

**Alternative A: Thin library wrapper (CHOSEN)**
- Add `setup_step_start/end/fail` helper functions in `scripts/lib/setup-telemetry.sh`
- Instrument existing scripts by wrapping each step with these helpers
- Checkpoint is a single JSON file at `~/.shipwright/setup-checkpoint.json`
- **Trade-offs**: Minimal blast radius (helpers + instrumentation), reuses `emit_event` infra, simple checkpoint format
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Installation and Setup Telemetry with Automatic Recovery Checkpoint System
## Context
## Decision
## Alternatives Considered
## Component Diagram
## Interface Contracts
## Data Flow
## Error Boundaries
## Schema Changes
## Idempotency Strategy
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 92,
      "summary": "Documents test failures in sw-cleanup.sh (heartbeat staleness detection) and sed invocations. Recovery/checkpoint systems depend on proper cleanup and state management. These are blocking test failures the build stage must address."
    },
    {
      "file": "patterns.json (detailed config)",
      "relevance": 78,
      "summary": "Defines project structure: Node.js, vitest test runner, npm, src/ directory, *.test.js pattern, CommonJS imports. Essential for the build stage to execute tests and validate telemetry checkpoint system correctly."
    },
    {
      "file": "patterns.json (minimal)",
      "relevance": 42,
      "summary": "Confirms project_type: nodejs from bootstrap phase. Less detailed than other patterns.json entry but provides redundant validation of project type."
    },
    {
      "file": "metrics.json",
      "relevance": 8,
      "summary": "Empty baselines object. Could be populated with performance metrics for telemetry/checkpoint system, but currently provides no actionable data for build stage."
    },
    {
      "file": "decisions.json",
      "relevance": 5,
      "summary": "Empty decisions array. Architectural decisions about telemetry/recovery system would be relevant, but none are currently documented."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Installation and Setup Telemetry with Automatic Recovery Checkpoint System — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Installation and Setup Telemetry with Automatic Recovery Checkpoint System

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/setup-telemetry.sh` with checkpoint read/write and step tracking helpers
- [ ] Task 2: Add `--resume` flag parsing to `scripts/sw-init.sh` and source setup-telemetry.sh
- [ ] Task 3: Instrument all 14 steps in `scripts/sw-init.sh` with `setup_step_start/end/fail`
- [ ] Task 4: Instrument `scripts/sw-setup.sh` phases with telemetry and `--resume` passthrough
- [ ] Task 5: Instrument `install.sh` prereq checks with telemetry
- [ ] Task 6: Add section 9 "SETUP STATUS" to `scripts/sw-doctor.sh`
- [ ] Task 7: Update `config/event-schema.json` with setup.* event types
- [ ] Task 8: Create `scripts/sw-setup-telemetry-test.sh` test suite
- [ ] Task 9: Register test suite in `package.json`
- [ ] Task 10: Run full test suite, fix any failures
- [ ] `scripts/lib/setup-telemetry.sh` exists with all documented functions
- [ ] Running `shipwright setup` creates `~/.shipwright/setup-checkpoint.json`
- [ ] Each setup step emits `setup.step` event to `events.jsonl` with step name, duration, and status
- [ ] `shipwright setup --resume` skips completed steps and resumes from last failure
- [ ] `shipwright doctor` reports incomplete setup with `--resume` suggestion
- [ ] `config/event-schema.json` includes `setup.started`, `setup.step`, `setup.completed`, `setup.resumed`
- [ ] Test suite passes: `./scripts/sw-setup-telemetry-test.sh`
- [ ] `npm test` passes (no regressions)
- [ ] Checkpoint file expires after 24h (stale checkpoints don't block fresh installs)
- [ ] `--repair` flag ignores existing checkpoint (forces clean start)

## Context
- Pipeline: standard
- Branch: feat/installation-and-setup-telemetry-with-au-210
- Issue: #210
- Generated: 2026-03-08T00:47:35Z

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **observability**: Metrics must be emitted even when recovery runs; inject telemetry at entry/exit of each setup step and verify emissions reach the event bus
- **testing-strategy**: Recovery paths cannot be tested via full reruns; design synthetic failure injection (mock step failures) to validate recovery logic without 30min rerun cycles

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
- **Latency shift**: p95 latency increases >50% from baseline

### Log Analysis
- Search for new ERROR/FATAL/PANIC entries not present before deploy
- Check for stack traces — they indicate unhandled exceptions
- Look for retry storms — repeated failed attempts at the same operation
- Monitor for resource exhaustion messages (OOM, connection refused, disk full)

### Auto-Rollback Triggers
Automatically rollback if ANY of these occur:
- Health check fails 3 consecutive times
- Error rate exceeds threshold for 2+ minutes
- Critical service dependency becomes unreachable
- Memory usage exceeds 90% of limit

### Monitoring by Issue Type

**Frontend changes:**
- JavaScript error rates in browser (if client-side monitoring exists)
- Asset load failures (404s on new bundles)
- Core Web Vitals regression (LCP, FID, CLS)

**API changes:**
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


## Failure Diagnosis (Iteration 2)
Classification: unknown
Strategy: retry_with_context
Repeat count: 0"
iteration: 2
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-08T01:12:33Z
last_iteration_at: 2026-03-08T01:12:33Z
consecutive_failures: 0
total_commits: 2
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-03-08T01:06:38Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":696384,"duration_api_ms":670855,"num_turns":109,"res

### Iteration 2 (2026-03-08T01:12:33Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":170027,"duration_api_ms":139193,"num_turns":29,"resu

