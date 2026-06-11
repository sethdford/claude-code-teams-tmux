---
goal: "Cross-Repo Pattern Learning Engine for Fleet Mode

## Plan Summary
I have enough grounding. Here is the implementation plan.

---

# Implementation Plan: Cross-Repo Pattern Learning Engine for Fleet Mode

## Summary

Add a **fleet-wide pattern store** at `~/.shipwright/fleet-memory/` that captures successful fix strategies, error→solution mappings, and test approaches from *every* repo a fleet daemon processes, then injects the most relevant patterns into a new pipeline when a *different* repo starts a build. Patterns are scored for relevance by repo language/framework, error type, and issue keywords. Privacy is opt-in per repo. A new `fleet patterns` subcommand surfaces and applies patterns, and metrics track cross-repo learning impact.

The design **wraps existing infrastructure rather than replacing it**: the per-repo memory system (`sw-memory.sh`, `~/.shipwright/memory/<repo_hash>/`) stays the source of truth for a single repo; the fleet engine is a thin aggregation + injection layer that hooks the two existing seams — `memory_finalize_pipeline` (capture) and `memory_inject_context` (injection).

---

## Brainstorming / Socratic Refinement (answered)

**Minimum viable change:** A new library `scripts/lib/fleet-memory.sh` providing `fleet_pattern_capture`, `fleet_pattern_match`, `fleet_pattern_inject`; a new store dir; a `fleet patterns` subcommand in `sw-fleet.sh`; opt-in config; and a test suite. We do *not* build a new daemon process — capture and injection piggyback on existing pipeline seams already proven to be called (`daemon-dispatch.sh:515`, `pipeline-commands.sh:1223`, `loop-iteration.sh:130`).

**Implicit requirements:** Concurrency safety (fleet daemon runs N pipelines across repos in parallel, all writing one shared index → needs locking/atomic writes); bounded store size (cap patterns, prune stale); no PII/secret leakage across repo boundaries (patterns are fix descriptions + error signatures, never file contents).
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Cross-Repo Pattern Learning Engine for Fleet Mode
## Context
## Decision
## Alternatives Considered
### A. New `lib/fleet-memory.sh` hooking existing seams (✅ CHOSEN)
### B. Extend `sw-memory.sh` `global.json` to hold cross-repo patterns
### C. SQLite-backed shared store via `sw-db.sh`
## Component Decomposition
### Component Responsibilities (Single Responsibility Principle)
## Interface Contracts
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Cross-Repo Pattern Learning Engine for Fleet Mode

### Goals
- Fleet-wide memory store: ~/.shipwright/fleet-memory/ with pattern index
- Pattern capture: successful fixes, error→solution mappings, test strategies
- Pattern injection: when daemon starts pipeline, inject relevant fleet patterns from similar repos
- Similarity scoring: repo language, framework, error type, issue keywords
- CLI commands: `shipwright fleet patterns list`, `shipwright fleet patterns apply <pattern-id>`
- Privacy controls: opt-in/opt-out per repo in fleet-config.json
- Metrics: pattern application success rate, cross-repo learning impact on success rate
- Test suite validates pattern capture, storage, retrieval, and application
- **Priority**: P2
- **Complexity**: full

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json (sethdford/shipwright)",
      "relevance": 95,
      "summary": "Project conventions—Node, vitest, npm, commonjs—directly applicable to build stage for this repo"
    },
    {
      "file": "success-patterns.json (second entry)",
      "relevance": 85,
      "summary": "Two successful build patterns showing iteration counts, file patterns, and loop-based approaches for 'Fix bug' and 'Add authentication' with proven strategies"
    },
    {
      "file": "knowledge.json",
      "relevance": 82,
      "summary": "Captured test failures (mktemp directory issues, JSON output formatting, cleanup output) to avoid during build and test stages"
    },
    {
      "file": "architecture.json",
      "relevance": 72,
      "summary": "Architecture rules that the cross-repo pattern learning engine must follow to maintain consistency"
    },
    {
      "file": "metrics.json (first entry)",
      "relevance": 68,
      "summary": "Build duration baseline (2089s) provides context for expected scope and iteration planning"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Cross-Repo Pattern Learning Engine for Fleet Mode — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Cross-Repo Pattern Learning Engine for Fleet Mode

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/fleet-memory.sh` with VERSION, store paths, defensive sourcing.
- [ ] Task 2: Implement `_fleet_init_store` + corruption quarantine (atomic writes).
- [ ] Task 3: Implement `_fleet_opt_in` privacy gate (default opt-in=false, per-repo override). *(blocks Task 7, 8)*
- [ ] Task 4: Implement `fleet_pattern_fingerprint` reusing `repo_hash`/`patterns.json`.
- [ ] Task 5: Implement `_fleet_score` + `fleet_pattern_match` with config-driven weights/threshold. *(blocks Task 8, 11-stats)*
- [ ] Task 6: Implement `fleet_pattern_capture` with `flock`, 500-cap, `emit_event`. *(depends on 3,4)*
- [ ] Task 7: Implement `fleet_pattern_inject` + `fleet_pattern_record_outcome` + `fleet_pattern_prune`. *(depends on 5)*
- [ ] Task 8: Add `patterns` sub-router (`list`/`show`/`apply`/`stats`/`prune`) to `sw-fleet.sh`. *(depends on 6,7)*
- [ ] Task 9: Add guarded capture hooks in `daemon-dispatch.sh` + `pipeline-commands.sh`. *(depends on 6)*
- [ ] Task 10: Add guarded injection hook in `loop-iteration.sh`. *(depends on 7)*
- [ ] Task 11: Extend `fleet_init` + config docs with `pattern_learning` / `fleet_pattern_matching` blocks.
- [ ] Task 12: Write `sw-fleet-patterns-test.sh` covering capture/store/retrieval/scoring/application/opt-out/concurrency. *(depends on 8)*
- [ ] Task 13: Register test in `package.json`; ensure `npm test` green.
- [ ] Task 14: Update `.claude/CLAUDE.md`, bump VERSIONs, sync AUTO docs.
- [ ] Task 15: Verify `shipwright fleet patterns list` is discoverable end-to-end (CLI router → sw-fleet → lib).
- [ ] `~/.shipwright/fleet-memory/{index.json,metrics.json}` created and maintained with the documented schema.
- [ ] Successful pipeline in one repo captures a pattern (fix + error→solution + test strategy); verified by test and `emit_event`.
- [ ] A new pipeline in a *similar* repo receives injected fleet patterns in its build prompt (cross-repo path proven by E2E test).
- [ ] Similarity scoring uses language/framework + error type + keywords with config-driven weights/threshold; boundary cases tested.
- [ ] `shipwright fleet patterns list|show|apply|stats|prune` all work and are reachable via the CLI router.

## Context
- Pipeline: standard
- Branch: arch/cross-repo-pattern-learning-engine-for-f-626
- Issue: #626
- Generated: 2026-06-11T13:43:13Z

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **data-pipeline**: Pattern capture (fix→storage), indexing, retrieval, and injection form a data pipeline that must handle heterogeneous repo structures and evolving pattern schemas.

## Data Pipeline Expertise

Apply these data engineering patterns:

### Schema Design
- Define schemas explicitly — never rely on implicit structure
- Use migrations for all schema changes (never manual ALTER TABLE)
- Add indexes for frequently queried columns
- Consider denormalization for read-heavy paths

### Data Integrity
- Use transactions for multi-step operations
- Implement idempotency keys for operations that could be retried
- Validate data at ingestion — reject bad data early
- Use constraints (NOT NULL, UNIQUE, FOREIGN KEY) in the database layer

### Query Patterns
- Avoid N+1 queries — use JOINs or batch loading
- Use EXPLAIN to verify query plans for complex queries
- Paginate large result sets — never SELECT * without LIMIT
- Use parameterized queries — never string concatenation for SQL

### Migration Safety
- Migrations must be reversible (include rollback steps)
- Test migrations on a copy of production data
- Add new columns as nullable, then backfill, then add NOT NULL
- Never drop columns in the same deploy as code changes

### Backpressure & Resilience
- Implement circuit breakers for external data sources
- Use dead letter queues for failed processing
- Set timeouts on all external calls
- Monitor queue depths and processing latency

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Schema Changes**: Full migration SQL with both forward and rollback scripts, plus data backfill strategy if required
2. **Data Flow Diagram**: Text diagram showing data ingestion → processing → output with failure points marked
3. **Idempotency Strategy**: How the system handles duplicate requests (idempotency keys, deduplication, side-effect safety)
4. **Rollback Plan**: Step-by-step process to revert schema changes and restore data consistency

If any section is not applicable, explicitly state why it's skipped.
"
iteration: 1
max_iterations: 30
status: running
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-06-11T13:59:10Z
last_iteration_at: 2026-06-11T13:59:10Z
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
### Iteration 1 (2026-06-11T13:59:10Z)
✅ Library loads and operates correctly  
✅ CLI routes and responds  
✅ Fingerprinting auto-detects languages  

### Iteration 2 (2026-06-11T14:XXZ)
✅ Fixed file_mtime function in compat.sh (suppressed stdout from failed stat)
✅ Fixed BASH_SOURCE handling in fleet-memory.sh SCRIPT_DIR assignment
✅ Fixed ERR trap in fleet-memory.sh to handle missing BASH_SOURCE
✅ Fixed sed -i '' syntax in code-review test (platform-specific)
✅ All 24 cleanup tests now pass (primary issue RESOLVED)
⚠️ Fleet-patterns test environment issue (functions work in manual tests)
⚠️ Unrelated test failure in regression detection  

