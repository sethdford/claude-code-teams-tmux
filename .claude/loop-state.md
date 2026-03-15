---
goal: "Extract Hardcoded Timeouts from sw-daemon.sh to policy.json

## Plan Summary


Now I have a complete picture. Let me produce the implementation plan.

---

# Implementation Plan: Extract Hardcoded Timeouts from sw-daemon.sh to policy.json

## Brainstorming & Design Analysis

### Requirements Clarity

**Minimum viable change**: Add a `daemon_timeouts` section to `config/policy.json` for the ~8-10 truly hardcoded timeout values in `sw-daemon.sh` (values that currently have NO config path), update the script to read them via `policy_get()` with fallbacks matching current values. Zero behavior change.

**Implicit requirements**: The schema file (`config/policy.schema.json`) must be updated to validate new fields. The existing daemon test suite must still pass. The existing `daemon` section in policy.json already covers some values (poll_interval, heartbeat_timeout, etc.) — we must NOT duplicate those.

### What's Actually Hardcoded vs. Already Configurable

After thorough analysis, these values in `sw-daemon.sh` are **truly hardcoded with no config path**:
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Extract Hardcoded Timeouts from sw-daemon.sh to policy.json
## Context
## Decision
## Component Diagram
## Interface Contracts
## Data Flow
## Error Boundaries
## Alternatives Considered
## Implementation Plan
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 52,
      "summary": "Contains test failure patterns from sw-daemon.sh and related scripts. Understanding past test failures (stale heartbeat detection, test output issues) helps avoid regressions when refactoring daemon configuration extraction."
    },
    {
      "file": "patterns.json (first entry with repo context)",
      "relevance": 38,
      "summary": "Provides project structure, test patterns (*.test.js), and testing conventions for the shipwright repo. Useful for understanding how to properly test the timeout extraction feature once implemented."
    },
    {
      "file": "metrics.json",
      "relevance": 15,
      "summary": "Could contain baseline daemon metrics/performance data, but is currently empty. Potentially relevant if baselines are populated to validate timeout extraction doesn't break daemon behavior."
    },
    {
      "file": "patterns.json (project_type: nodejs detection)",
      "relevance": 12,
      "summary": "Generic project detection metadata. Minimally relevant—confirms Node.js context but doesn't inform bash script refactoring or policy.json configuration."
    },
    {
      "file": "patterns.json (empty patterns from test_repo)",
      "relevance": 8,
      "summary": "Empty patterns array from test_repo. Not applicable to the shipwright daemon refactoring task."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Extract Hardcoded Timeouts from sw-daemon.sh to policy.json — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Extract Hardcoded Timeouts from sw-daemon.sh to policy.json

## Implementation Checklist
- [ ] Task 1: Add `daemon.timeouts` section to `config/policy.json` with all 11 default values
- [ ] Task 2: Add schema validation for `daemon.timeouts` in `config/policy.schema.json`
- [ ] Task 3: Update `rotate_event_log()` to read from policy (2 values)
- [ ] Task 4: Update `gh_retry()` to read retry config from policy (3 values)
- [ ] Task 5: Update SIGTERM grace wait in shutdown handler (1 value)
- [ ] Task 6: Update graceful shutdown loop to read from policy (3 values)
- [ ] Task 7: Update watchdog backoff to read from policy (2 values)
- [ ] Task 8: Add test cases for custom timeout configuration
- [ ] Task 9: Run full test suite to verify no regressions
- [ ] Task 10: Validate policy.json with `jq empty config/policy.json`
- [ ] All 11 hardcoded timeout values in sw-daemon.sh read from `config/policy.json` via `policy_get()`
- [ ] Each value falls back to the original hardcoded constant when config is absent
- [ ] `config/policy.json` contains `daemon.timeouts` section with documented defaults
- [ ] `config/policy.schema.json` validates the new section with min/max ranges
- [ ] `npm test` passes (all existing tests green, no regressions)
- [ ] Daemon behavior is identical when using default values (zero behavior change)
- [ ] Platform health scan shows ~11 fewer hardcoded values

## Context
- Pipeline: standard
- Branch: refactor/extract-hardcoded-timeouts-from-sw-daemo-280
- Issue: #280
- Generated: 2026-03-15T02:49:09Z

## Skill Guidance (refactor issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: Systematic approach to test default path (no config present), custom values within range, invalid values, and timeout interactions that could cause cascade failures
- **config-extraction-safety**: Concrete patterns for safe extraction with proper fallback semantics, validation rules, and common pitfalls specific to daemon configuration refactoring

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

## Configuration Extraction Safety Pattern

When extracting hardcoded values to configurable settings, follow these proven patterns to ensure safety, backward compatibility, and correctness:

### 1. Safe Extraction with Fallback
```bash
# Pattern: Read from config, fall back to original hardcoded value
POLL_INTERVAL=$(jq '.daemon_timeouts.poll_interval // empty' config/policy.json 2>/dev/null || echo '')
POLL_INTERVAL=${POLL_INTERVAL:-30}  # Original hardcoded value becomes fallback
```

This ensures:
- Users without policy.json changes see identical behavior
- Fallback value documents the current/original behavior
- No breaking changes if config section is missing
- Transparent migration path for existing deployments

### 2. Validation Before Use
```bash
# Always validate extracted values against safe ranges
validate_timeout() {
  local value=$1 min=$2 max=$3 name=$4
  if ! [[ $value =~ ^[0-9]+$ ]] || (( value < min || value > max )); then
    error "Invalid timeout '$name': $value (must be integer $min-$max seconds)"
    return 1
  fi
}

validate_timeout "$POLL_INTERVAL" 5 300 "poll_interval"
```

Validation prevents silent configuration errors and provides clear operator feedback.

### 3. Configuration Structure with Documentation
```json
{
  "daemon_timeouts": {
    "poll_interval": 30,
    "health_check_interval": 60,
    "cleanup_interval": 300,
    "retry_delay_base": 5,
    "_comment": "All times in seconds. Ranges: poll 5-300, health 10-600, cleanup 60-3600, retry 1-30"
  }
}
```

Inline documentation prevents users from setting invalid values.

### 4. Testing Matrix for Configuration Values

**Backward Compatibility** (config absent):
- Daemon starts and behaves identically to before extraction
- All timeouts match original hardcoded values
- No config file required for existing deployments

**Default Config Path** (config with recommended values):
- Daemon starts with config file present
- Behavior remains identical to original hardcoded behavior

**Custom Values** (within safe range):
- Test conservative values (larger timeouts - slower but safer)
- Test aggressive values (smaller timeouts within range - faster polling)
- Verify dependent timeouts work together (e.g., health_check < poll_interval)

**Invalid Values** (detect and reject):
- Non-numeric values → validation error, clear message
- Zero or negative → validation error with safe range
- Extreme values (9999999) → validation error with max range
- Missing optional fields → use fallback values
- Type mismatches (string vs number) → validation error

### 5. Common Pitfalls to Avoid

1. **No validation** → Invalid config silently breaks daemon behavior or causes hangs
2. **Missing fallback** → Removing or updating config breaks existing deployments
3. **Unrelated timeouts grouped** → Changes to poll_interval shouldn't require understanding health_check
4. **No interaction testing** → Cascading/dependent timeouts may deadlock under specific combinations
5. **Insufficient documentation** → Users don't understand safe ranges and cause production incidents
6. **Silent failures** → Warn clearly if fallback is used due to invalid config

### 6. Documentation Requirements for Each Extracted Value

For each timeout extracted to config:
- **Current value**: Original hardcoded value (reference/default)
- **Purpose**: When/why this timeout is used in the daemon lifecycle
- **Safe range**: Minimum and maximum recommended values
- **Impact of change**: What happens if too high (missed events?) or too low (high CPU?)
- **Dependencies**: Other timeouts that must be coordinated with this one

### 7. Verification Checklist

- [ ] All hardcoded timeout values identified and documented
- [ ] Fallback values match original hardcoded values exactly
- [ ] Validation enforces safe ranges with clear error messages
- [ ] Default config/policy.json section provided and documented
- [ ] Tested without config present (backward compatibility verified)
- [ ] Tested with custom values within safe range
- [ ] Tested with invalid values (proper error handling and messaging)
- [ ] Tested timeout interactions and cascading effects
- [ ] No behavior change when using default values
- [ ] Operator documentation covers safe ranges and rationale

### 8. Safe Rollout Strategy

1. **Stage 1**: Deploy with fallback defaults (no config changes required)
2. **Stage 2**: Provide optional config/policy.json with recommended values
3. **Stage 3**: Document use cases for custom timeouts (e.g., high-load environments)
4. **Stage 4**: Monitor for validation errors in logs (indicates invalid user config)
5. **Stage 5**: Gather feedback on timeout ranges from production deployments


## Failure Diagnosis (Iteration 2)
Classification: unknown
Strategy: retry_with_context
Repeat count: 0"
iteration: 2
max_iterations: 10
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-15T03:29:37Z
last_iteration_at: 2026-03-15T03:29:37Z
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
### Iteration 1 (2026-03-15T02:59:34Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":301954,"duration_api_ms":270843,"num_turns":63,"resu

