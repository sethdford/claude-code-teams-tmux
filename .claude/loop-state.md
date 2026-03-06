---
goal: "Project Type Auto-Detection and Template Recommendation Engine

## Plan Summary
The implementation plan has been written to `.claude/plan.md`. Here's a summary:

## Plan Summary

**Approach**: New library module (`scripts/lib/project-type-detection.sh`) + CLI subcommand (`shipwright detect`), integrated into existing `prep` and `setup` commands. Heuristic-first with multi-signal scoring.

### Key Design Decisions
- **Additive, not disruptive** — existing `prep_detect_stack()` untouched; new functions layer on top
- **Multi-signal scoring** — each project type (web/cli/library/infrastructure) gets scored independently; highest score wins with confidence based on margin
- **Offline-first** — file existence checks and grep patterns; no Claude API required for basic detection

### Files to Create (4)
1. `scripts/lib/project-type-detection.sh` — core detection library (~300 lines)
2. `scripts/sw-detect.sh` — CLI command (~150 lines)
3. `scripts/sw-detect-test.sh` — test suite (~400 lines)
4. `templates/project-types/` — project type profile JSONs

### Files to Modify (4)
5. `scripts/sw-prep.sh` — integrate detection (~20 lines)
6. `scripts/sw-setup.sh` — show detection in Phase 2 (~10 lines)
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions

[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 95,
      "summary": "Contains current project type (node/javascript), test runner (vitest), source conventions (src/, *.test.js), and import style—directly applicable to build stage decisions and test execution"
    },
    {
      "file": "patterns.json",
      "relevance": 38,
      "summary": "Basic project type detection (nodejs) from earlier bootstrap, but minimal detail; superseded by more recent and detailed patterns entry"
    },
    {
      "file": "failures.json",
      "relevance": 22,
      "summary": "No recorded failures to learn from, but indicates this is a fresh build with no prior regressions to watch for"
    },
    {
      "file": "metrics.json",
      "relevance": 12,
      "summary": "Empty baselines; no prior performance metrics available for comparison during build stage"
    },
    {
      "file": "decisions.json",
      "relevance": 8,
      "summary": "No architectural decisions captured; minimal value for current build stage"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Project Type Auto-Detection and Template Recommendation Engine — Resolution: 

## Failure Diagnosis (Iteration 2)
Classification: unknown
Strategy: retry_with_context
Repeat count: 0"
iteration: 2
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-06T07:16:51Z
last_iteration_at: 2026-03-06T07:16:51Z
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
### Iteration 1 (2026-03-06T06:46:47Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":32113,"duration_api_ms":626323,"num_turns":6,"result

