---
goal: "Success Pattern Capture and Proven Configuration Replay System

## Plan Summary
# Implementation Plan: Success Pattern Capture and Proven Configuration Replay System

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change**: A library that (1) captures the full configuration tuple when a pipeline succeeds, (2) looks up the most similar proven config when a new pipeline starts, and (3) applies it as the starting configuration. This closes the gap where individual parameters are tuned independently but the winning *combination* is never saved.

**Implicit requirements**:
- Must not break existing adaptive/self-optimize flows — additive only
- Must handle repos with zero history (graceful fallback to defaults)
- Must track whether replayed configs continue to succeed (feedback loop)
- Must respect Bash 3.2 compatibility, atomic writes, `set -euo pipefail`

**Acceptance criteria**:
1. After a successful pipeline, a proven config entry is persisted with full config tuple + issue context
2. `shipwright proven-configs list` shows captured configs with success rates
3. `shipwright proven-configs match --issue N` finds the best matching config
4. Pipeline intake consults proven configs before falling back to defaults
5. Replay outcomes are tracked and configs with declining success are demoted
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Success Pattern Capture and Proven Configuration Replay System
## Context
## Decision
### Architecture: Four-Layer Design
### Why This Design
## Alternatives Considered
### Alternative A: New focused library + CLI (CHOSEN)
### Alternative B: Extend sw-self-optimize.sh
### Alternative C: Extend sw-adaptive.sh with multi-dimensional tuning
## Implementation Plan
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 98,
      "summary": "Core failure patterns with root causes and proven fixes (up to 16 occurrences). Directly aligns with 'Success Pattern Capture and Proven Configuration Replay System' — provides exact data to replay for build stage recovery."
    },
    {
      "file": "patterns.json (detailed)",
      "relevance": 85,
      "summary": "Complete project configuration (vitest, npm, source_dir, test_pattern). Essential for build stage to apply correct test commands and directory structure."
    },
    {
      "file": "patterns.json (minimal)",
      "relevance": 45,
      "summary": "Basic project_type detection (nodejs). Provides metadata but overlaps with detailed patterns.json; less actionable for build stage."
    },
    {
      "file": "metrics.json",
      "relevance": 25,
      "summary": "Empty baselines structure. Relevant for future success metric tracking but currently provides no data to replay or act on."
    },
    {
      "file": "global.json",
      "relevance": 10,
      "summary": "Empty common patterns and cross-repo learnings. Lowest relevance; no actionable data present."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Success Pattern Capture and Proven Configuration Replay System — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Success Pattern Capture and Proven Configuration Replay System

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/proven-configs.sh` with core functions (capture, match, apply, track, prune, list, stats, scoring)
- [ ] Task 2: Create `scripts/sw-proven-configs.sh` CLI command with subcommands (list, show, match, stats, prune, reset, help)
- [ ] Task 3: Source `lib/proven-configs.sh` from pipeline-stages loader so it's available during pipeline execution
- [ ] Task 4: Integrate proven config capture into `scripts/lib/pipeline-commands.sh` after successful pipeline completion
- [ ] Task 5: Integrate proven config lookup into `scripts/lib/pipeline-stages-intake.sh` during intake stage
- [ ] Task 6: Integrate replay outcome tracking into `scripts/lib/pipeline-commands.sh` at pipeline finalization
- [ ] Task 7: Register `proven-configs` subcommand in `scripts/sw` CLI router
- [ ] Task 8: Create `scripts/sw-proven-configs-test.sh` test suite with 16 test cases
- [ ] Task 9: Register test suite in `package.json`
- [ ] Task 10: Run test suite and fix any failures
- [ ] `scripts/lib/proven-configs.sh` exists with all documented functions
- [ ] `scripts/sw-proven-configs.sh` exists with all subcommands (list, show, match, stats, prune, reset, help)
- [ ] `shipwright proven-configs help` shows usage and exits 0
- [ ] `shipwright proven-configs list` works on empty repo (shows "no configs")
- [ ] Successful pipeline completion creates a proven config entry in `~/.shipwright/proven-configs/<repo-hash>/configs.jsonl`
- [ ] Pipeline intake consults proven configs and applies matching config when available
- [ ] Replay outcomes are tracked and confidence scores updated after each replay
- [ ] Configs with replay success rate <40% after 5+ replays are automatically demoted
- [ ] `shipwright proven-configs prune` removes stale configs
- [ ] Test suite has 16 test cases, all passing

## Context
- Pipeline: autonomous
- Branch: ci/issue-257
- Issue: none
- Generated: 2026-03-13T18:56:55Z

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
- Step back and reconsider the requirements"
iteration: 4
max_iterations: 20
status: running
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-03-13T19:54:12Z
last_iteration_at: 2026-03-13T19:54:12Z
consecutive_failures: 0
total_commits: 4
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-03-13T19:11:21Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":364462,"duration_api_ms":352251,"num_turns":65,"resu

### Iteration 2 (2026-03-13T19:19:09Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":346610,"duration_api_ms":241436,"num_turns":87,"resu

### Iteration 3 (2026-03-13T19:28:31Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":332679,"duration_api_ms":285788,"num_turns":67,"resu

### Iteration 4 (2026-03-13T19:54:12Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":696922,"duration_api_ms":171553,"num_turns":74,"resu

