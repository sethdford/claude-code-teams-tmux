---
goal: "Build Loop Intelligent Session Restart Briefing System

## Plan Summary
# Implementation Plan: Build Loop Intelligent Session Restart Briefing System

## Socratic Design Analysis

### Requirements Clarity

**Minimum viable change**: Create `scripts/lib/loop-restart-briefing.sh` with four enhanced analysis functions (git diff categorization, error pattern extraction/prioritization, iteration history summarization, next-steps recommendation) and integrate them into the existing `restart_generate_briefing()` flow in `session-restart.sh`.

**Implicit requirements**:
- Must not break the existing restart flow — `restart_before_restart()` orchestrates 6 functions; the new module enhances `restart_generate_briefing()` output quality
- Must stay under ~2000 token budget for briefings (existing test enforces this)
- Must handle edge cases: no git changes, no errors, no archived iterations, empty error-summary.json
- Must follow module guard pattern, atomic writes, Bash 3.2 compatibility

**Acceptance criteria** (from issue):
1. New script `lib/loop-restart-briefing.sh` — generates structured restart context
2. Analyzes git diff and categorizes changes (source, test, docs, config)
3. Extracts and prioritizes error patterns from error-summary.json
4. Summarizes iteration history: what worked, what failed, why
5. Generates focused next-steps based on remaining work
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Build Loop Intelligent Session Restart Briefing System
## Context
## Decision
### Design Principles
## Alternatives Considered
## Implementation Plan
### Files to Create
### Files to Modify
### Dependencies
### Risk Areas
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 75,
      "summary": "Contains 26+ test failures including heartbeat detection and cleanup issues. Directly relevant to build stage blockers. Session restart briefing needs to handle these failure patterns to provide context on previous failed iterations."
    },
    {
      "file": "patterns.json (first entry with source_dir/test_pattern)",
      "relevance": 68,
      "summary": "Defines project structure: test_runner=vitest, language=javascript, package_manager=npm. Essential for understanding how to execute the build and tests in the loop iterations."
    },
    {
      "file": "patterns.json (second entry with project_type: nodejs)",
      "relevance": 32,
      "summary": "Confirms nodejs project type at a high level. Minimal specificity—the first patterns.json entry provides more actionable build details."
    },
    {
      "file": "patterns.json (third entry with empty patterns array)",
      "relevance": 8,
      "summary": "References test_repo (not shipwright), has no patterns data. Not relevant to this codebase."
    },
    {
      "file": "metrics.json",
      "relevance": 2,
      "summary": "Empty baselines object. No actionable metrics for session restart briefing."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Build Loop Intelligent Session Restart Briefing System — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Build Loop Intelligent Session Restart Briefing System

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/loop-restart-briefing.sh` with module boilerplate and `briefing_categorize_changes()`
- [ ] Task 2: Implement `briefing_extract_error_patterns()` with cross-iteration aggregation and deduplication
- [ ] Task 3: Implement `briefing_summarize_iterations()` reading archived session data
- [ ] Task 4: Implement `briefing_recommend_next_steps()` with context-aware recommendations
- [ ] Task 5: Implement `briefing_generate_enhanced()` main entry point composing all sections
- [ ] Task 6: Modify `session-restart.sh` `restart_generate_briefing()` to call enhanced generator with fallback
- [ ] Task 7: Add source line in `sw-loop.sh` for the new module
- [ ] Task 8: Create `scripts/sw-loop-restart-briefing-test.sh` test suite (~14 tests)
- [ ] Task 9: Add 2 integration tests to `scripts/sw-session-restart-test.sh`
- [ ] Task 10: Register new test in `package.json`
- [ ] Task 11: Update `.claude/CLAUDE.md` Build Loop Capabilities documentation
- [ ] Task 12: Run test suite and fix any failures
- [ ] `scripts/lib/loop-restart-briefing.sh` exists with 5 public functions
- [ ] Git diff categorization correctly separates source/test/config/docs files
- [ ] Error patterns deduplicated and ranked by frequency across all iterations
- [ ] Iteration history summarizes approaches tried and outcomes per session
- [ ] Next-step recommendations are context-aware (different for stuck_loop vs context_exhaustion vs tests_passing)
- [ ] `restart_generate_briefing()` uses enhanced briefing when available, falls back to basic
- [ ] `sw-loop.sh` sources the new module
- [ ] All new tests pass: `./scripts/sw-loop-restart-briefing-test.sh`

## Context
- Pipeline: standard
- Branch: feat/build-loop-intelligent-session-restart-b-273
- Issue: #273
- Generated: 2026-03-15T08:09:50Z

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
status: running
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-03-15T09:42:00Z
last_iteration_at: 2026-03-15T09:42:00Z
consecutive_failures: 0
total_commits: 5
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-03-15T08:22:17Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":339709,"duration_api_ms":311480,"num_turns":68,"resu

### Iteration 2 (2026-03-15T08:34:55Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":484225,"duration_api_ms":251692,"num_turns":93,"resu

### Iteration 3 (2026-03-15T09:00:38Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":1024207,"duration_api_ms":276359,"num_turns":82,"res

### Iteration 4 (2026-03-15T09:31:00Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":742937,"duration_api_ms":217870,"num_turns":61,"resu

### Iteration 5 (2026-03-15T09:42:00Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":110036,"duration_api_ms":97806,"num_turns":28,"resul

