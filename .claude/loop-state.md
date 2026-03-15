---
goal: "Pipeline Failure Debug Artifact Auto-Collector

## Plan Summary
# Pipeline Failure Debug Artifact Auto-Collector — Implementation Plan

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change:** A single library module (`scripts/lib/debug-collector.sh`) that, when a pipeline stage fails, automatically gathers all relevant debug artifacts into a structured bundle (`$ARTIFACTS_DIR/debug-bundles/<stage>-<epoch>-<pid>/`). This bundle is then referenced in the GitHub failure comment and retry context so that agents and humans can diagnose failures without manually hunting for logs.

**Implicit requirements:**
- Must not slow down the failure path (collection must be fast, <2s)
- Must not break existing retry/checkpoint/memory flows
- Must work in worktree isolation (parallel pipelines)
- Must respect `$NO_GITHUB` for local mode
- Must be Bash 3.2 compatible (no associative arrays, no `readarray`)

**Acceptance criteria (self-defined):**
1. On any stage failure, a debug bundle directory is created containing: stage log, error classification, environment snapshot, git state, pipeline state, recent events, and error-log.jsonl tail
2. The bundle path is included in the GitHub issue comment on failure
3. The bundle is referenced in `.retry-context-<stage>.md` for retry agents
4. A `shipwright debug-bundle` CLI command lists/shows/exports bundles
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Pipeline Failure Debug Artifact Auto-Collector
## Context
## Decision
## Alternatives Considered
### 1. Event-Driven Async Collection (Rejected)
### 2. Extend error-log.jsonl with Richer Context (Rejected)
### 3. Per-Attempt Bundles in Retry Loop (Rejected)
## Component Decomposition
### 1. Debug Collector Library (`scripts/lib/debug-collector.sh`)
### 2. Pipeline Failure Integration (`scripts/lib/pipeline-state.sh`)
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 98,
      "summary": "Core failure artifact data with 5 documented failure patterns, root causes, fixes, and metadata (stage, seen_count, timestamps). Directly matches the artifact collector's purpose of capturing pipeline failures."
    },
    {
      "file": "patterns.json (first entry)",
      "relevance": 72,
      "summary": "Project configuration (node/vitest/npm, src/ directory, commonjs imports, test pattern) provides context for build stage execution and test invocation conventions."
    },
    {
      "file": "metrics.json",
      "relevance": 28,
      "summary": "Empty baseline structure; potentially relevant as a target schema for collecting build/test metrics, but currently contains no useful data."
    },
    {
      "file": "patterns.json (second entry, minimal)",
      "relevance": 22,
      "summary": "Basic nodejs project type with detection timestamp; redundant with first patterns.json and provides minimal context beyond project language."
    },
    {
      "file": "patterns.json (third entry, test_repo)",
      "relevance": 12,
      "summary": "Empty patterns from external test_repo with cache metadata; minimal relevance to this repo's build stage context."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Pipeline Failure Debug Artifact Auto-Collector — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Pipeline Failure Debug Artifact Auto-Collector

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/debug-collector.sh` with `collect_debug_bundle()`, `rotate_debug_bundles()`, `list_debug_bundles()`, `show_debug_bundle()`, `export_debug_bundle()`
- [ ] Task 2: Create `scripts/sw-debug-bundle.sh` CLI command with `list`, `show`, `export`, `clean`, `last` subcommands (depends on Task 1)
- [ ] Task 3: Modify `scripts/lib/pipeline-state.sh` — call `collect_debug_bundle()` from `mark_stage_failed()` and include bundle path in GitHub failure comment (depends on Task 1)
- [ ] Task 4: Modify `scripts/lib/pipeline-execution.sh` — reference debug bundle in retry context file (depends on Task 1)
- [ ] Task 5: Register `debug-bundle` subcommand in `scripts/sw` CLI router (depends on Task 2)
- [ ] Task 6: Register `debug.bundle_created` event type in `config/event-schema.json`
- [ ] Task 7: Create `scripts/sw-debug-bundle-test.sh` test suite with 12 test cases (depends on Tasks 1-6)
- [ ] Task 8: Register test suite in `package.json` (depends on Task 7)
- [ ] Task 9: Run test suite and fix any failures
- [ ] Task 10: Run existing pipeline tests to verify no regressions
- [ ] `collect_debug_bundle()` creates a complete bundle on every stage failure
- [ ] Bundle contains: stage log, error classification, environment (secrets filtered), git state, pipeline state, recent events, error log tail, manifest
- [ ] Bundles are auto-rotated (max 10 by default)
- [ ] GitHub failure comment includes bundle path
- [ ] Retry context file includes bundle contents for agent consumption
- [ ] `shipwright debug-bundle list|show|export|clean|last` CLI works
- [ ] `debug.bundle_created` event emitted and schema-registered
- [ ] Test suite passes with 12+ test cases
- [ ] Existing pipeline tests pass (no regressions)
- [ ] All scripts use `set -euo pipefail`, Bash 3.2 compatible, VERSION synced

## Context
- Pipeline: autonomous
- Branch: ci/issue-278
- Issue: none
- Generated: 2026-03-15T07:55:47Z

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
- Step back and reconsider the requirements

## Failure Diagnosis (Iteration 6)
Classification: unknown
Strategy: alternative_approach
Repeat count: 4
INSTRUCTION: This error has occurred 4 times. The previous approach is not working. Try a FUNDAMENTALLY DIFFERENT approach:
- If you were modifying existing code, try rewriting the function from scratch
- If you were using one library, try a different one
- If you were adding to a file, try creating a new file instead
- Step back and reconsider the requirements"
iteration: 6
max_iterations: 20
status: error
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-03-15T09:51:10Z
last_iteration_at: 2026-03-15T09:51:10Z
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
### Iteration 1 (2026-03-15T08:12:55Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":539677,"duration_api_ms":478319,"num_turns":108,"res

### Iteration 2 (2026-03-15T08:26:10Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":2651,"duration_api_ms":204380,"num_turns":1,"result"

### Iteration 3 (2026-03-15T08:36:41Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":393880,"duration_api_ms":115097,"num_turns":32,"resu

### Iteration 4 (2026-03-15T08:57:49Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":900813,"duration_api_ms":147012,"num_turns":53,"resu

### Iteration 5 (2026-03-15T09:39:26Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":30007,"duration_api_ms":300120,"num_turns":9,"result

