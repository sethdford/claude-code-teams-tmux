---
goal: "Config-Driven Policy Engine with JSON Schema and Adaptive Override System

## Plan Summary
Here is the implementation plan:

---

## Plan: Config-Driven Policy Engine

### Key finding: most infrastructure already exists

`config/policy.json`, `config/policy.schema.json`, `scripts/lib/policy.sh`, and `scripts/lib/config.sh` are all already in place. The work is closing **five specific gaps**:

### Five gaps to close

| Gap | Root Cause |
|-----|-----------|
| Schema broken | `policy.json` has a `decision` section but schema has `additionalProperties: false` with no `decision` property — schema validation fails today |
| Missing loop values | sw-loop.sh has 14+ hardcoded env-var fallbacks (`MAX_ITERATIONS=20`, `EXTENSION_SIZE=5`, `test_timeout=900`, etc.) that bypass the policy system |
| No policy-overrides.json | sw-adaptive.sh writes learned data to `~/.shipwright/adaptive-models.json` only — no bridge to the policy system |
| No schema validation on load | `policy_get` only calls `jq -r`, no constraint checking |
| sw-doctor.sh has zero policy checks | Completely absent |
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Config-Driven Policy Engine with JSON Schema and Adaptive Override System
## Context
## Decision
### 1. Override Precedence Chain
### 2. Schema Repair
### 3. Policy Values in `policy.json`
### 4. Schema Validation in Bash via `jq`
### 5. Script Migration Pattern
# sw-loop.sh — before
# sw-loop.sh — after  
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json (first entry)",
      "relevance": 88,
      "summary": "Defines actual project structure: Node.js with vitest, npm, CommonJS imports, src/ directory. Critical for understanding build environment and conventions."
    },
    {
      "file": "success-patterns.json (first entry)",
      "relevance": 82,
      "summary": "Contains two successful patterns from similar-complexity builds (60-65 complexity), both using standard template and npm test strategy. Shows 3-4 iteration approach."
    },
    {
      "file": "failures.json (fifth entry)",
      "relevance": 76,
      "summary": "Build-stage failures with variable initialization and declaration errors. Shows both 100% and 66% fix effectiveness rates, directly applicable to JavaScript build debugging."
    },
    {
      "file": "failures.json (second entry)",
      "relevance": 72,
      "summary": "Build-stage failures from variable initialization (100% fix effectiveness). Provides mitigation patterns for common JavaScript runtime errors in build phase."
    },
    {
      "file": "failures.json (third entry)",
      "relevance": 65,
      "summary": "ENOENT dependency issue (95% fix effectiveness via npm install). Relevant for build stage dependency validation before compilation."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Config-Driven Policy Engine with JSON Schema and Adaptive Override System — Resolution: "
iteration: 1
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-04-04T01:22:03Z
last_iteration_at: 2026-04-04T01:22:03Z
consecutive_failures: 0
total_commits: 1
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-04-04T01:22:03Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":740748,"duration_api_ms":716548,"num_turns":97,"resu

