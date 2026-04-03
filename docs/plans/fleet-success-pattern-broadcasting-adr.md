# Design: Fleet-Wide Success Pattern Broadcasting with Real-Time Cross-Repo Learning

## Context

Fleet mode (`sw-fleet.sh`) orchestrates daemons across multiple repos with a shared worker pool, but each repo's memory system (`sw-memory.sh`) learns only from its own pipeline history. When a Go API repo discovers that "extract middleware into shared package" succeeds across 4 repos, other repos in the fleet don't benefit — they rediscover the same approach from scratch.

**Problem:** Success patterns are siloed per-repo. No mechanism propagates what worked fleet-wide.

**Constraints from the codebase:**

- **Transport:** The shared event bus (`~/.shipwright/events.jsonl`) is already the fleet's inter-component communication layer — fleet start/stop, rebalance, and machine-offline events all flow through it. 7-day TTL cleanup via `eventbus clean`.
- **Storage:** Global memory (`~/.shipwright/memory/<repo-hash>/global.json`) already stores `common_patterns[]` and `cross_repo_learnings[]`. The `_memory_aggregate_global()` function (sw-memory.sh:628-662) promotes high-frequency repo patterns into global memory.
- **Injection:** `memory_inject_context()` (sw-memory.sh:977-1219) already reads global memory and injects cross-repo learnings at the end of every stage's context block (lines 1194-1215).
- **Concurrency:** Multiple fleet repos finalize pipelines concurrently. All file writes must be atomic (tmp + mv).
- **Compatibility:** Bash 3.2 — no associative arrays, no `readarray`, no `${var,,}`.
- **No fleet config = no broadcasting:** Repos not in fleet mode must be completely unaffected.

## Decision

**Extend `sw-fleet.sh` (orchestration) + `sw-memory.sh` (storage) using the existing event bus for transport.** No new modules. Five files modified, one test file created.

### Data Flow

```
Pipeline success (exit_code=0)
  → pipeline-commands.sh:~807 emits fleet.pattern.success event
    (guarded by .claude/fleet-config.json existence)
  → ~/.shipwright/events.jsonl

Pipeline finalize (any repo in fleet)
  → memory_finalize_pipeline() calls new step 4: memory_ingest_fleet_patterns()
  → reads fleet.pattern.success events from events.jsonl (last 7 days)
  → deduplicates by SHA256(normalized_goal) = pattern_hash
  → increments cross_repo_success_count only when source_repo is new
  → writes to global.json .fleet_patterns[] (capped at 200 entries)
  → atomic write: mktemp + jq + mv

Future pipeline (build or plan stage)
  → memory_inject_context() reads global.json .fleet_patterns[]
  → filters by project type compatibility (node→node, go→go)
  → patterns with cross_repo_success_count > 3 get +10 relevance boost
  → injected as "Fleet-Proven Patterns" section in memory context
```

### Event Schema

```jsonc
// Emitted to events.jsonl on pipeline success (only in fleet mode)
{
  "ts": "2026-04-03T10:00:00Z",
  "type": "fleet.pattern.success",
  "source_repo": "org/api-service",       // owner/repo from git remote
  "goal": "Add rate limiting to endpoints", // truncated to 200 chars
  "approach": "intake,plan,build,test,review,pr",
  "files_changed": 12,
  "test_strategy": "vitest",               // from patterns.json
  "duration_s": 1200,
  "complexity": 45,                         // from intelligence cache
  "template": "standard",                   // pipeline template used
  "pattern_hash": "a1b2c3..."              // SHA256 of normalized goal
}
```

### Storage Schema (global.json)

```jsonc
// New additive key in global.json (backward-compatible — existing code ignores unknown keys)
{
  "common_patterns": [],          // existing
  "cross_repo_learnings": [],     // existing
  "fleet_patterns": [             // NEW
    {
      "pattern_hash": "a1b2c3...",
      "source_repo": "org/api-service",
      "goal": "Add rate limiting to endpoints",
      "approach": "intake,plan,build,test,review,pr",
      "template": "standard",
      "test_strategy": "vitest",
      "complexity": 45,
      "avg_duration_s": 1200,
      "cross_repo_success_count": 4,
      "repos_succeeded": ["org/api-service", "org/web-app", "org/cli", "org/sdk"],
      "first_seen": "2026-04-01T10:00:00Z",
      "last_seen": "2026-04-03T15:30:00Z",
      "adopted_count": 7
    }
  ]
}
```

### Deduplication & Idempotency

- **Pattern identity:** SHA256 hash of normalized goal text (lowercased, stripped of issue numbers and trailing whitespace).
- **Same repo, same goal:** Updates `last_seen` only — `cross_repo_success_count` stays unchanged.
- **New repo, existing goal:** Appends to `repos_succeeded` (capped at 20), increments count.
- **New goal:** Inserts new entry. If fleet_patterns exceeds 200 entries, evicts the entry with lowest `cross_repo_success_count` (ties broken by oldest `last_seen`).
- **All writes atomic:** `tmp=$(mktemp "${file}.tmp.XXXXXX"); jq ... > "$tmp" && mv "$tmp" "$file"`.

### Error Handling

| Failure | Behavior |
|---------|----------|
| `events.jsonl` missing or unwritable | `emit_event` creates `~/.shipwright/` dir; writes are `|| true` — silent skip |
| Malformed event JSON in events.jsonl | `jq` with `2>/dev/null` skips bad lines; ingestion continues |
| `global.json` missing | `memory_ingest_fleet_patterns` creates it with `{"fleet_patterns": []}` |
| Concurrent writers to global.json | Atomic tmp+mv prevents corruption; last-writer-wins may undercount by 1 (acceptable for advisory data; `repos_succeeded` array provides ground truth for recalculation) |
| `.claude/fleet-config.json` absent | Event emission skipped entirely — zero fleet code executes |
| Dashboard reads missing global.json | Returns `{"total_patterns": 0, ...}` — empty stats |

### Project Type Filtering

During `memory_inject_context()`, fleet patterns are filtered by project type before injection:

- Read `patterns.json .project.type` for the current repo (e.g., "node", "go", "python")
- Only inject fleet patterns where `test_strategy` matches the current project's ecosystem OR the pattern goal is project-agnostic (no language-specific keywords)
- Prevents a Go repo from receiving "use pytest fixtures" advice from a Python fleet member

## Alternatives Considered

1. **Extend `sw-discovery.sh`** — Discovery already has `broadcast_discovery()` (sw-discovery.sh:71-105) and bus integration.
   - Pros: Reuses existing fleet broadcast infra; discovery already has semantic matching and a query API
   - Cons: Discovery has 24h TTL (`DISCOVERY_TTL_SECS`) — success patterns need persistence. Discovery is semantically "real-time learnings during execution," not "post-completion aggregated patterns." Changing discovery TTL would break in-pipeline learning semantics. Blast radius: medium.

2. **New standalone module (`sw-fleet-patterns.sh`)** — Dedicated script with its own storage, pub/sub, and CLI.
   - Pros: Zero risk to existing code; clean separation of concerns
   - Cons: Duplicates event bus integration from sw-eventbus.sh, memory storage patterns from sw-memory.sh, and jq aggregation from `_memory_aggregate_global()`. Adds 500+ lines that parallel existing infrastructure. Violates the project convention of "don't create files unless necessary." Maintenance burden of keeping two pattern storage systems in sync.

3. **Direct file writes to peer repos** — Fleet coordinator writes patterns directly into each repo's memory directory.
   - Pros: No event bus dependency; immediate propagation
   - Cons: Requires filesystem access to all repo memory dirs (breaks when repos are on remote machines or in worktrees with different paths). `discovery_fleet_broadcast` already proved this approach fragile. Race conditions multiply with N repos. No deduplication layer.

4. **WebSocket-based real-time push** — Dashboard server relays patterns to connected repos.
   - Pros: True real-time with no polling
   - Cons: No persistent server in fleet mode (dashboard is optional). Repos not connected to dashboard get nothing. Adds hard dependency on dashboard infrastructure. Events.jsonl is already the canonical transport.

## Implementation Plan

### Files to create

| File | Lines | Purpose |
|------|------:|---------|
| `scripts/sw-fleet-patterns-test.sh` | ~400 | 12 test cases: event emission, dedup, cap, injection boost, CLI, JSON output, empty state, concurrent write safety |

### Files to modify

| File | Change | Lines added | Insertion point |
|------|--------|------------:|-----------------|
| `scripts/lib/pipeline-commands.sh` | Emit `fleet.pattern.success` event after existing `pipeline.completed` event on success path | ~20 | After line 806 (after `emit_event "pipeline.completed"` in the `exit_code -eq 0` branch) |
| `scripts/sw-memory.sh` | Add `memory_ingest_fleet_patterns()` function; add step 4 call in `memory_finalize_pipeline()`; add fleet-proven patterns section in `memory_inject_context()` for build/plan stages | ~150 | New function before line 665; step 4 at line 679; fleet injection in plan/design case (after line 1051) and build case (after line 1099) |
| `scripts/sw-fleet.sh` | Add `fleet_patterns_show()` function with `--top N` and `--json` flags; wire `patterns` into command router; update `show_help()` | ~120 | New function before line 1345; router case at line 1367 |
| `dashboard/server.ts` | Add `GET /api/fleet/learning-stats` endpoint returning `FleetLearningStats` JSON | ~50 | Near existing `/api/status` handler around line 2759 |

### Dependencies

None. All changes use existing infrastructure:
- `emit_event` from sw-eventbus.sh (already sourced in pipeline-commands.sh)
- `jq` for JSON manipulation (required dependency, checked by `shipwright doctor`)
- `sha256sum` or `shasum` for pattern hashing (standard Unix utilities)
- `mktemp` + `mv` for atomic writes (POSIX)

### Risk areas

1. **`memory_inject_context()` context window bloat** (Medium risk) — Injecting fleet patterns adds tokens to every build/plan stage prompt. Mitigated by: cap at 5 fleet patterns per injection, each truncated to goal + approach + count (no full metadata). Monitor via `memory.inject` event payload size.

2. **`memory_finalize_pipeline()` latency** (Low risk) — New step 4 reads events.jsonl and writes global.json. At fleet scale (500 events/week), jq filtering is <100ms. The `2>/dev/null || true` wrapper prevents any failure from blocking pipeline completion.

3. **SHA256 hash collisions across goal normalization** (Very low risk) — Two meaningfully different goals could hash identically if normalization is too aggressive. Mitigated by: normalization only lowercases and strips issue numbers/whitespace, preserving semantic content.

4. **global.json schema migration** (No risk) — `fleet_patterns` is a new additive key. Existing code reads `common_patterns` and `cross_repo_learnings` and ignores unknown keys. Rollback: `jq 'del(.fleet_patterns)' global.json`.

## Endpoint Specification

### `GET /api/fleet/learning-stats`

**Request:** No body. Optional query parameters:
- `top` (integer, default 10, max 50) — number of top patterns to return

**Response (200 OK):**
```json
{
  "total_patterns": 42,
  "patterns_shared": 18,
  "patterns_adopted": 7,
  "success_lift_pct": 16.7,
  "top_patterns": [
    {
      "pattern_hash": "a1b2c3...",
      "goal": "Add rate limiting to endpoints",
      "approach": "intake,plan,build,test,review,pr",
      "template": "standard",
      "cross_repo_success_count": 4,
      "repos_succeeded": ["org/api", "org/web", "org/cli", "org/sdk"],
      "first_seen": "2026-04-01T10:00:00Z",
      "last_seen": "2026-04-03T15:30:00Z",
      "adopted_count": 7
    }
  ]
}
```

**Response (500 Internal Server Error):**
```json
{
  "error": { "code": "GLOBAL_MEMORY_READ_FAILED", "message": "Could not read global.json" }
}
```

**When global.json is missing or has no `fleet_patterns` key**, return 200 with zeroed stats (not an error — empty state is valid).

### `shipwright fleet patterns` CLI

```
Usage: shipwright fleet patterns [--top N] [--json]

Options:
  --top N    Show top N patterns (default: 10, max: 50)
  --json     Output raw JSON instead of formatted table

Output (table mode):
  # Fleet-Wide Success Patterns
  ┌──────┬──────────────────────────────────────┬───────┬───────┬──────────┐
  │ Rank │ Goal                                 │ Repos │ Times │ Template │
  ├──────┼──────────────────────────────────────┼───────┼───────┼──────────┤
  │    1 │ Add rate limiting to endpoints       │     4 │     7 │ standard │
  │    2 │ Refactor auth middleware             │     3 │     5 │ full     │
  └──────┴──────────────────────────────────────┴───────┴───────┴──────────┘
  
  Total: 42 patterns | 18 shared across repos | 7 adopted

Exit codes:
  0  Success
  1  Fleet config not found or no patterns available
```

### Error Codes

| Code | Status | Condition |
|------|--------|-----------|
| 200 | OK | Stats returned (including empty stats) |
| 500 | Internal Server Error | `GLOBAL_MEMORY_READ_FAILED` — jq parse failure or I/O error on global.json |

### Rate Limiting

Not applicable. This endpoint reads a local JSON file (~50KB max). No external API calls, no authentication concerns. The dashboard already runs locally and is not exposed to the internet by default. If exposed via `public-dashboard`, it inherits the existing authentication middleware (session cookie check at server.ts:505-515).

### Versioning

No API versioning needed. This is the first version of this endpoint. The response schema is additive — future fields can be added without breaking clients. If a breaking change is ever needed (field removal/rename), the existing dashboard client lives in the same repo, so coordinated updates are trivial.

## Monitoring Checklist

### P0 — Immediate (first pipeline run after deploy)

| Metric | Threshold | How to check |
|--------|-----------|--------------|
| Event emission | `fleet.pattern.success` event appears in events.jsonl after pipeline success in fleet mode | `grep "fleet.pattern.success" ~/.shipwright/events.jsonl` |
| No emission outside fleet | Zero `fleet.pattern.success` events when `.claude/fleet-config.json` absent | Run pipeline without fleet config, verify no events |
| Existing tests pass | `npm test` exit 0 | CI pipeline |
| Pipeline completion unaffected | Pipeline finalize latency unchanged (new step 4 adds <100ms) | Compare pipeline.completed event `duration_s` before/after |

### P1 — Short-term (first fleet run with multiple repos)

| Metric | Threshold | How to check |
|--------|-----------|--------------|
| Pattern ingestion | `fleet_patterns[]` populated in global.json after 2+ repos complete | `jq '.fleet_patterns | length' ~/.shipwright/memory/*/global.json` |
| Dedup correctness | Same repo + same goal = count stays at 1 | Re-run same pipeline, check `cross_repo_success_count` unchanged |
| Cross-repo increment | Different repo + same goal = count increments | Complete same goal in second repo, verify count = 2 |
| Cap enforcement | fleet_patterns never exceeds 200 entries | `jq '.fleet_patterns | length' global.json` after many runs |

### P2 — Medium-term (after 1 week of fleet usage)

| Metric | Threshold | How to check |
|--------|-----------|--------------|
| Context injection | Fleet-proven patterns appear in build/plan stage memory context | Check pipeline logs for "Fleet-Proven Patterns" section |
| events.jsonl size | Growth <1MB/week from fleet pattern events | `ls -la ~/.shipwright/events.jsonl` over time |
| global.json size | <500KB (200 patterns × ~500 bytes each) | `ls -la global.json` |
| Dashboard endpoint | `/api/fleet/learning-stats` returns correct aggregates | `curl localhost:PORT/api/fleet/learning-stats` |

## Anomaly Detection Triggers

| Condition | Detection | Action |
|-----------|-----------|--------|
| **Spike:** >50 `fleet.pattern.success` events in 1 hour | `shipwright eventbus watch --type fleet.pattern.success` shows burst | Investigate — likely a fleet running many parallel pipelines. Not harmful (events are small), but check if pattern dedup is working correctly |
| **Absence:** Fleet running but zero `fleet.pattern.success` events in 24 hours | `grep fleet.pattern.success ~/.shipwright/events.jsonl` returns nothing despite successful pipelines | Check that fleet-config.json exists in each repo; verify pipeline-commands.sh changes are deployed |
| **Stale data:** `fleet_patterns[].last_seen` oldest entry >30 days | `jq '[.fleet_patterns[].last_seen] | sort | first' global.json` | Consider adding TTL-based eviction (not in v1 — cap at 200 suffices) |
| **Injection bloat:** Memory context exceeds 4000 tokens | Monitor `memory.inject` event; measure injected context size | Reduce fleet pattern injection from 5 to 3 entries, or truncate goal text further |

## Log Analysis

- **New event type:** Search for `fleet.pattern.success` in events.jsonl to confirm emission is working.
- **Ingestion errors:** Search for `memory_ingest_fleet_patterns` in pipeline logs (stderr) — any `jq` parse errors will appear here despite `2>/dev/null` in production; enable verbose logging with `SHIPWRIGHT_DEBUG=1`.
- **Atomic write failures:** `mktemp` failures will produce "No such file or directory" in stderr — indicates `/tmp` is full or `~/.shipwright/memory/` dir is missing.
- **Pattern hash computation:** `sha256sum` or `shasum` not found → pattern_hash will be empty → dedup breaks → all events treated as unique. Check with `which sha256sum || which shasum`.

## Auto-Rollback Decision Criteria

This feature is advisory-only (it enriches pipeline context but does not gate any pipeline stage), so the blast radius of a bug is limited to injecting bad context. Automatic rollback is **not applicable** — there is no deployment step, health check, or external service dependency. Instead:

- **If fleet patterns inject irrelevant context** (wrong project type leaking through): Fix the project type filter in `memory_inject_context()`. Patterns already in global.json are harmless — they won't be injected after the filter fix.
- **If global.json is corrupted by a write race**: The `repos_succeeded` array is ground truth. Delete `fleet_patterns` key and let re-ingestion rebuild from events.jsonl: `jq 'del(.fleet_patterns)' global.json > tmp && mv tmp global.json`.
- **If pipeline finalize hangs** (extremely unlikely — `|| true` wrapper): The `memory_ingest_fleet_patterns` call has `2>/dev/null || true`, so it cannot block. If it somehow does, the pipeline stall detector (sw-stall-detector.sh) will catch it.
- **Full rollback**: Revert the 4 modified files. Optionally clean: `jq 'del(.fleet_patterns)' global.json`. No data loss, no schema migration, no external state.

## Validation Criteria

- [ ] `fleet.pattern.success` events appear in `~/.shipwright/events.jsonl` after successful pipeline runs when `.claude/fleet-config.json` exists
- [ ] No `fleet.pattern.success` events emitted when `.claude/fleet-config.json` is absent
- [ ] `global.json` contains `fleet_patterns[]` with correct `source_repo` tags after `memory_finalize_pipeline` runs
- [ ] Same repo completing same goal twice does not increment `cross_repo_success_count`
- [ ] Different repo completing same goal increments `cross_repo_success_count` and appends to `repos_succeeded`
- [ ] `fleet_patterns[]` never exceeds 200 entries — lowest-count entry evicted when cap reached
- [ ] `memory_inject_context("build")` and `memory_inject_context("plan")` include "Fleet-Proven Patterns" section for patterns with `cross_repo_success_count > 3`
- [ ] Fleet patterns filtered by project type — Go repo does not receive Python-specific patterns
- [ ] `shipwright fleet patterns --top 5` displays formatted table sorted by cross_repo_success_count desc
- [ ] `shipwright fleet patterns --json` outputs valid JSON parseable by `jq`
- [ ] `GET /api/fleet/learning-stats` returns correct `total_patterns`, `patterns_shared`, `patterns_adopted` counts
- [ ] All 12 test cases in `sw-fleet-patterns-test.sh` pass
- [ ] `npm test` passes with no regressions in existing test suites
- [ ] All file writes use atomic tmp+mv pattern (no direct `echo > file` or `jq ... > file`)
- [ ] All bash is 3.2-compatible — no associative arrays, no readarray, no `${var,,}`
