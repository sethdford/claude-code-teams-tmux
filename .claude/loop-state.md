---
goal: "Fleet-Wide Pattern Mining & Knowledge Transfer Engine

## Plan Summary
# Implementation Plan — Fleet-Wide Pattern Mining & Knowledge Transfer Engine

## Summary

Shipwright already captures learning at three disconnected altitudes:

- **Per-repo memory** (`~/.shipwright/memory/{repo_hash}/{failures,patterns,decisions,metrics}.json`) — rich, but siloed per repository.
- **Real-time discovery** (`~/.shipwright/discoveries.jsonl`) — ephemeral, 24h TTL, intra-fleet broadcast.
- **A thin `global.json`** (`common_patterns[]`, `cross_repo_learnings[]`) — populated opportunistically by `optimize_evolve_memory`, but with no systematic cross-repo *mining* step.

The gap this feature closes: **nothing periodically mines all per-repo memory stores, finds patterns that recur across *multiple* repos, scores their fleet-wide confidence, and transfers the consolidated knowledge back into new pipelines.** A failure fixed in repo A today does not benefit repo B's next build unless it happens to be live in the 24h discovery window.

This feature adds a **Fleet-Wide Pattern Mining & Knowledge Transfer Engine**: a new `shipwright knowledge` command (script `scripts/sw-knowledge.sh`) that (1) **mines** per-repo memory across the fleet, (2) **consolidates** recurring patterns into a durable `~/.shipwright/memory/fleet-knowledge.json` with cross-repo occurrence counts and confidence scores, and (3) **transfers** that knowledge by injecting fleet-wide patterns into pipeline stages — so a new repo benefits from learnings mined anywhere in the fleet.

### Design Reasoning (Socratic refinement — answered, not asked)

- **Minimum viable change?** A standalone bash module that reads existing per-repo memory JSON (already written by `sw-memory.sh`), aggregates by a stable pattern *signature*, and writes one consolidated `fleet-knowledge.json`, plus an `inject` path pipeline stages can call. We reuse all existing storage; no migration of existing files.
- **Implicit requirements?** Bash 3.2 compatible, `NO_GITHUB`-safe (this is pure local filesystem work — no GitHub needed), atomic writes, and **additive** (existing tests must pass — the sole stated acceptance criterion).
- **Two approaches considered** (see *Alternatives Considered*). Chosen: a **standalone mining module reading existing memory files**, because it minimizes blast radius — it *reads* existing data and writes one *new* file, touching no existing read/write paths in `sw-memory.sh`.
- **Reuse over rebuild:** signature/dedup logic mirrors `memory_capture_failure`; injection mirrors `memory_inject_context`; cross-repo promotion mirrors `optimize_evolve_memory`; confidence scoring mirrors `discovery_score_confidence`. We follow these patterns rather than invent new ones.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Fleet-Wide Pattern Mining & Knowledge Transfer Engine
## Context
## Decision
### Component Diagram
### Interface Contracts
### Data Flow
### Error Boundaries
## Alternatives Considered
## Implementation Plan
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Fleet-Wide Pattern Mining & Knowledge Transfer Engine

### Goals
- Fleet-Wide Pattern Mining & Knowledge Transfer Engine

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Recent test failures from 2026-06-19 (today) with documented root causes and fixes: sw-cleanup.sh output format issues, template error handling, mktemp directory creation. Critical for avoiding test failures during build."
    },
    {
      "file": "success-patterns.json",
      "relevance": 88,
      "summary": "Two complete build patterns: bug fix (60 complexity, 3 iterations, 45s) and auth feature (65 complexity, 3 iterations, 150s). Shows file patterns, test strategies (npm test), and commit workflow for successful builds."
    },
    {
      "file": "knowledge.json",
      "relevance": 85,
      "summary": "Knowledge base with 4 documented failure patterns and fixes: mktemp directory creation (occurrences: 4), cleanup.sh output format (occurrences: 2), regression detection JSON validation. Enables pattern recognition to avoid repeated failures."
    },
    {
      "file": "patterns.json",
      "relevance": 82,
      "summary": "Current project structure from 2026-06-19: Node.js project with vitest test runner, commonjs imports, src/ source directory, *.test.js pattern. Essential baseline for build environment setup."
    },
    {
      "file": "issues.json",
      "relevance": 70,
      "summary": "Past successful issue resolution showing: daemon timeout bug fix using semaphore pattern. Demonstrates troubleshooting approach for complex shell script issues affecting build stability."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Fleet-Wide Pattern Mining & Knowledge Transfer Engine — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Fleet-Wide Pattern Mining & Knowledge Transfer Engine

## Implementation Checklist
- [ ] Task 1: Scaffold `sw-knowledge.sh` with house boilerplate + `VERSION=3.3.0`
- [ ] Task 2: Implement `ensure_knowledge_file`, `km_atomic_write`, `km_signature`, `km_iter_repos`
- [ ] Task 3: Implement `cmd_mine` (extract → group by signature → score confidence → atomic write)
- [ ] Task 4: Implement `cmd_transfer` (additive promotion into `global.json`, capped/deduped)
- [ ] Task 5: Implement `cmd_inject` (Jaccard tag ranking → injectable context, bump metrics)
- [ ] Task 6: Implement `cmd_search`, `cmd_show`, `cmd_report`, `show_help`
- [ ] Task 7: Implement `main()` case dispatch with unknown-command handling
- [ ] Task 8: Register `knowledge|mine` subcommand in `scripts/sw`
- [ ] Task 9: Write `sw-knowledge-test.sh` (cross-repo collapse, confidence bounds, inject, transfer, malformed input)
- [ ] Task 10: Register test in `package.json` `test` script
- [ ] Task 11: `shipwright docs sync` + add Fleet Knowledge doc note
- [ ] Task 12: Run `npm test`; verify all suites pass (acceptance criterion)
- [ ] `scripts/sw-knowledge.sh` exists, executable, `set -euo pipefail`, `VERSION` matches `package.json`.
- [ ] `shipwright knowledge mine` produces a valid `~/.shipwright/memory/fleet-knowledge.json`; cross-repo patterns merge by signature with correct `repo_count`/`total_occurrences`.
- [ ] `shipwright knowledge inject <task_type>` emits ranked, relevant injectable context; `transfer` updates `global.json` additively.
- [ ] `knowledge` (and `mine` alias) dispatch correctly from `scripts/sw`.
- [ ] `sw-knowledge-test.sh` passes and is registered in `package.json`.
- [ ] All writes atomic (tmp + `mv`); any GitHub-touching code (none expected) guarded by `NO_GITHUB`; all `jq` uses `--arg`.
- [ ] No Bash 3.2 violations.
- [ ] `npm test` is green — **all existing tests continue to pass** (spec acceptance criterion).

## Context
- Pipeline: autonomous
- Branch: ci/issue-668
- Issue: none
- Generated: 2026-06-19T14:13:01Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-06-19T14:16:49Z
last_iteration_at: 2026-06-19T14:16:49Z
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

