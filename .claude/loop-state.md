---
goal: "Cross-Pipeline Result Cache with Change-Based Invalidation

## Plan Summary
# Implementation Plan — Cross-Pipeline Result Cache with Change-Based Invalidation

## Summary

Add a cache that lets an expensive, deterministic pipeline **stage** (e.g. `plan`,
`design`, `spec_generation`) reuse a prior run's artifact — **across different
pipeline runs on the same repo** — when its inputs are unchanged. "Change-based
invalidation" means the cache key embeds a content fingerprint of the stage's
inputs (goal + issue body + repo source state). Any relevant change flips the
fingerprint → cache miss → the stage re-runs normally. On a hit, the stage's
artifact file(s) are restored into `.claude/pipeline-artifacts/` and the Claude
invocation is skipped.

The feature ships **disabled by default** behind a `result_cache.enabled` flag so it
can roll out safely. It mirrors three proven in-repo patterns: the intelligence cache
(`.claude/intelligence-cache.json` → `{entries:{hash:{result,timestamp,ttl}}}`), the
GraphQL file-cache (`~/.shipwright/github-cache/`), and the discovery layer's
cross-run store under `$HOME`.

---
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Cross-Pipeline Result Cache with Change-Based Invalidation
## Context
## Decision
### Component Diagram
### Data flow
### Interface Contracts
### Loop wiring (exact, matching `pipeline-execution.sh:769–786`)
## Alternatives Considered
## Implementation Plan
### Error Boundaries
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Cross-Pipeline Result Cache with Change-Based Invalidation

### Goals
- Cross-Pipeline Result Cache with Change-Based Invalidation

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{"error":"memory_search_failed","results":[]}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Cross-Pipeline Result Cache with Change-Based Invalidation — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Cross-Pipeline Result Cache with Change-Based Invalidation

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/result-cache.sh` scaffold (header, VERSION, dirs, source guard).
- [ ] Task 2: Implement `result_cache_enabled` gate (config + tool availability).
- [ ] Task 3: Implement `result_cache_fingerprint` (git HEAD + porcelain hash + goal/body), subshell-safe.
- [ ] Task 4: Implement `_result_cache_init` + atomic `entries.json` seeding.
- [ ] Task 5: Implement `result_cache_get` (key, TTL age check, hit/miss events).
- [ ] Task 6: Implement `result_cache_store` with `jq --arg`, atomic `mv`, `max_entries` eviction.
- [ ] Task 7: Implement `result_cache_try_restore` + `result_cache_save` hooks (artifact I/O).
- [ ] Task 8: Wire both hooks into `pipeline-execution.sh` stage loop, fully guarded.
- [ ] Task 9: Source lib in `pipeline-stages.sh`/`bootstrap.sh` with no-op fallback.
- [ ] Task 10: Create `scripts/sw-result-cache.sh` CLI (`stats/list/get/clear/invalidate/prune/help`).
- [ ] Task 11: Register command in `scripts/sw` router.
- [ ] Task 12: Add `result_cache` block to `.claude/daemon-config.json` (disabled).
- [ ] Task 13: Write `scripts/sw-result-cache-test.sh`; register in `package.json`.
- [ ] Task 14: Update `.claude/CLAUDE.md` (Result Cache section, script tables, runtime-state).
- [ ] Task 15: Run `shipwright version check`, `shellcheck`, and new + related test suites.
- [ ] Three new files exist and pass `shellcheck` (bash 3.2 safe: no `declare -A`, `readarray`, `${var,,}`/`${var^^}`).
- [ ] With `result_cache.enabled=false` (default), pipeline behaves **identically** — hooks are provable no-ops (regression suites green).
- [ ] With the flag on: a second run over an **unchanged** repo restores `plan.md`/`design.md`/`spec.json` and skips the Claude call (verified via `result_cache.hit`).
- [ ] Any tracked/untracked change, changed goal/issue body, or TTL expiry produces a **miss** (tests 3 & 4) — no stale artifact ever served.
- [ ] Only `cacheable_stages` are cached; `build`/`test`/`pr`/`merge`/`deploy` never restored.

## Context
- Pipeline: autonomous
- Branch: ci/issue-725
- Issue: none
- Generated: 2026-07-03T14:50:00Z"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-07-03T14:54:18Z
last_iteration_at: 2026-07-03T14:54:18Z
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

