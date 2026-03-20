---
goal: "Issue Scope Hard Limit Pre-Flight Validator with Auto-Reject

## Plan Summary
The implementation plan has been written to `.claude/pipeline-artifacts/plan.md`.

**Summary of the plan:**

**Approach chosen:** Add scope validation to `pipeline_start()` in `pipeline-commands.sh` after `gh_init` — catches both daemon and CLI runs with minimal blast radius.

**New files (2):**
- `scripts/lib/preflight-scope.sh` — Core library with 4 functions: file count estimation, complexity estimation, scope validation, and rejection handler
- `scripts/sw-preflight-scope-test.sh` — 18 test cases

**Modified files (6):**
- `scripts/lib/pipeline-commands.sh` — Scope validation call after `gh_init`
- `scripts/lib/pipeline-cli.sh` — `--skip-preflight` flag
- `scripts/sw-pipeline.sh` — `SKIP_PREFLIGHT_SCOPE=false` default
- `config/policy.json` — `preflight_scope` defaults (max 15 files, max 8/10 complexity, max 500 body lines)
- `config/event-schema.json` — 2 new event types
- `package.json` — Test registration

**Key design decisions:**
- File-existence guard (`[[ -f preflight-scope.sh ]]`) means deleting the lib file disables the feature — safe rollback
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Issue Scope Hard Limit Pre-Flight Validator with Auto-Reject
## Context
## Decision
## Component Diagram
## Interface Contracts
## Data Flow
## Error Boundaries
## Alternatives Considered
### 1. Validation in daemon-dispatch.sh (before pipeline spawn)
### 2. New pipeline stage "preflight-validate" before intake
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 90,
      "summary": "Project configuration (vitest runner, src/ directory, commonjs imports) essential for build stage setup and test execution"
    },
    {
      "file": "failures.json",
      "relevance": 60,
      "summary": "Captured test failures including mktemp directory issues and sed invocation errors that may occur during build/test phases"
    },
    {
      "file": "patterns.json",
      "relevance": 40,
      "summary": "Node.js project type detection provides basic framework classification for build context"
    },
    {
      "file": "metrics.json",
      "relevance": 5,
      "summary": "Empty baselines; not applicable to current build stage"
    },
    {
      "file": "decisions.json",
      "relevance": 5,
      "summary": "Empty decisions log; no prior architectural decisions captured for this feature"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Issue Scope Hard Limit Pre-Flight Validator with Auto-Reject — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Issue Scope Hard Limit Pre-Flight Validator with Auto-Reject

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/preflight-scope.sh` with estimation and validation functions
- [ ] Task 2: Add `SKIP_PREFLIGHT_SCOPE=false` default in `sw-pipeline.sh` and `--skip-preflight` flag in `pipeline-cli.sh`
- [ ] Task 3: Integrate scope validation call into `pipeline_start()` in `pipeline-commands.sh` after `gh_init`
- [ ] Task 4: Add `preflight_scope` section to `config/policy.json` with default limits
- [ ] Task 5: Register new event types in `config/event-schema.json`
- [ ] Task 6: Create `scripts/sw-preflight-scope-test.sh` test suite with 18 test cases
- [ ] Task 7: Register test suite in `package.json`
- [ ] Task 8: Run test suite and verify all tests pass
- [ ] `preflight_scope_validate()` correctly rejects issues exceeding any configured limit
- [ ] `preflight_scope_validate()` correctly passes issues within all limits
- [ ] Rejection produces valid JSON in `preflight-rejection.json`
- [ ] Rejection comments on GitHub issue with decomposition guidance (when NO_GITHUB not set)
- [ ] Rejection adds `preflight-rejected` label and removes watch label
- [ ] All limits configurable via `daemon-config.json` or `policy.json`
- [ ] Setting any limit to 0 disables that specific check
- [ ] Setting `enabled: false` disables all scope checks
- [ ] `--skip-preflight` flag bypasses scope validation
- [ ] Events emitted for both pass and reject outcomes
- [ ] Test suite has >= 14 tests with 100% pass rate
- [ ] Existing pipeline tests continue to pass

## Context
- Pipeline: autonomous
- Branch: ci/issue-283
- Issue: none
- Generated: 2026-03-20T13:37:10Z"
iteration: 1
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-20T13:50:55Z
last_iteration_at: 2026-03-20T13:50:55Z
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
### Iteration 1 (2026-03-20T13:50:55Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":284797,"duration_api_ms":273882,"num_turns":38,"resu

