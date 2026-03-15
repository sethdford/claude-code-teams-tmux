---
goal: "daemon-config.json Schema Validator with Startup Check

## Plan Summary
Now I have sufficient context. Let me create a detailed implementation plan based on my analysis.

## Implementation Plan: daemon-config.json Schema Validator with Startup Check

### Analysis & Design Decisions

**Requirements Clarity:**
The goal is to validate `daemon-config.json` against a formal schema at daemon startup to prevent misconfiguration issues. The "minimum viable change" involves:
1. A JSON schema defining valid daemon-config.json structure
2. A validation library callable early in daemon startup
3. Clear error reporting for invalid configs
4. Test coverage for validation logic

**Design Alternatives Evaluated:**

| Approach | Pros | Cons | Chosen |
|----------|------|------|--------|
| **A: Pure bash jq validation in config.sh** | No new files, integrated | Complex bash logic, harder to test | ❌ |
| **B: Separate validator script + schema file** | Isolated, testable, clear separation | More files | ✅ |
| **C: Node.js TypeScript validator** | Powerful, modern | Adds Node dependency, not portable in daemon | ❌ |
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: daemon-config.json Schema Validator with Startup Check
## Context
## Decision
### Component Diagram
### Data Flow
### Interface Contracts
### Error Boundaries
## Alternatives Considered
## Implementation Plan
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json (sethdford/shipwright)",
      "relevance": 85,
      "summary": "Describes the project structure: Node.js, vitest test runner, npm, src/ source dir, CommonJS imports, *.test.js pattern. Directly relevant for understanding how to build and test the schema validator in this codebase."
    },
    {
      "file": "patterns.json (nodejs)",
      "relevance": 45,
      "summary": "Confirms Node.js project type with detection timestamp. Provides secondary validation of project language, less detailed than the primary patterns entry."
    },
    {
      "file": "failures.json",
      "relevance": 30,
      "summary": "Contains 5 test failure patterns from related Shipwright components (sw-cleanup, sw-feedback, etc.). May reveal common pitfalls in shell script testing and JSON output validation relevant to schema validation tests."
    },
    {
      "file": "patterns.json (empty patterns array)",
      "relevance": 8,
      "summary": "Extraction metadata only, no actionable patterns. Minimal relevance to build stage work."
    },
    {
      "file": "metrics.json",
      "relevance": 5,
      "summary": "Empty baselines object with no metrics data. No relevance to schema validator build."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for daemon-config.json Schema Validator with Startup Check — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — daemon-config.json Schema Validator with Startup Check

## Implementation Checklist
- [ ] Task 1: Write `config/daemon-config.schema.json` with complete property definitions
- [ ] Task 2: Implement `_validate_json_schema()` in lib/config-validate.sh (core validation)
- [ ] Task 3: Implement `_validate_daemon_config()` in lib/config-validate.sh (daemon-specific)
- [ ] Task 4: Implement error reporting functions in lib/config-validate.sh
- [ ] Task 5: Source config-validate.sh in sw-daemon.sh and call validation early
- [ ] Task 6: Add SKIP flag support for optional validation bypass
- [ ] Task 7: Write test suite covering valid/invalid configs
- [ ] Task 8: Test daemon startup with invalid config (should fail gracefully)
- [ ] Task 9: Test daemon startup with valid config (should succeed)
- [ ] Task 10: Test schema file missing scenario
- [ ] Task 11: Documentation — add schema validation to CLAUDE.md comment block
- [ ] Task 12: Verify all existing test suites still pass

## Context
- Pipeline: autonomous
- Branch: ci/issue-279
- Issue: none
- Generated: 2026-03-15T09:12:32Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-15T09:17:27Z
last_iteration_at: 2026-03-15T09:17:27Z
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

