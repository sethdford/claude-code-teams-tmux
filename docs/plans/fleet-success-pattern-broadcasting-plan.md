# Fleet-Wide Success Pattern Broadcasting — Implementation Plan

## Brainstorming: Socratic Design Refinement

### Requirements Clarity

**Minimum viable change:** When a pipeline succeeds in fleet mode, extract the success pattern (goal, approach, files changed) and broadcast it as an event. Other repos subscribe, ingest into their global memory with a `source_repo` tag, and prioritize patterns that have succeeded across 3+ repos. A CLI command and dashboard stats surface the data.

**Implicit requirements:**
- Must work with existing JSONL event bus (no new infrastructure)
- Must be backward-compatible — repos not in fleet mode should be unaffected
- Pattern deduplication — same pattern from same repo shouldn't stack
- Atomic writes throughout (tmp + mv pattern)
- Bash 3.2 compatible

**Acceptance criteria (from issue):**
1. sw-fleet.sh publishes pattern events to shared event bus on pipeline success
2. sw-memory.sh subscribes to fleet pattern events and writes to memory with `source_repo` tag
3. Pattern matching prioritizes fleet patterns with `cross_repo_success_count > 3`
4. Dashboard shows fleet learning stats
5. CLI: `shipwright fleet patterns --top 10`
6. Test suite validates event pub/sub and cross-repo pattern application

### Design Alternatives

**Approach A: Extend sw-discovery.sh** — Discovery already has `discovery_fleet_broadcast()` and bus integration. Add success patterns as another discovery type.
- Pro: Reuses existing infrastructure, minimal new code
- Con: Discovery is for real-time learnings *during* pipeline execution, not post-completion success patterns. Semantic mismatch. Discovery has 24h TTL — success patterns should be persistent.
- Blast radius: Medium — changes to discovery could affect in-pipeline learning

**Approach B: New module (sw-fleet-patterns.sh)** — Standalone script with its own storage, pub/sub, and CLI.
- Pro: Zero risk to existing code, clean separation
- Con: Duplicates event bus integration, memory storage patterns. Another 500+ line script. Violates "don't create files unless necessary."
- Blast radius: Low but high maintenance cost

**Approach C: Extend sw-fleet.sh + sw-memory.sh** — Fleet publishes events on success detection; memory ingests fleet patterns into global.json with source_repo tags. Uses existing event bus for transport.
- Pro: Follows existing architecture (fleet = orchestration, memory = storage, eventbus = transport). Minimal new files. Builds on `_memory_aggregate_global()` pattern.
- Con: Touches two core scripts
- Blast radius: Low — additive functions only, no modification of existing functions

**Chosen: Approach C** — It follows the existing separation of concerns (fleet orchestrates, memory stores, eventbus transports) and requires the least new infrastructure.

### Risk Assessment

1. **Event bus saturation** — Many success events could bloat events.jsonl. Mitigation: events.jsonl already has 7-day TTL cleanup; success patterns are low-frequency (only on pipeline success).
2. **Race conditions on global.json** — Multiple repos writing simultaneously. Mitigation: Atomic writes (tmp + mv) already used everywhere; jq operations are append-only.
3. **Stale patterns** — Patterns from repos that diverge architecturally. Mitigation: Include project type metadata; memory injection already filters by relevance score.
4. **Fleet not running** — Broadcasting when fleet is not active. Mitigation: Guard with fleet-config.json existence check; degrade gracefully.

---

## Architecture Decision Record

### ADR: Fleet Success Pattern Broadcasting via Event Bus

**Context:** Fleet mode orchestrates daemons across repos but repos learn only from their own history. Success patterns (what goal, approach, and test strategy worked) should propagate fleet-wide.

**Decision:** Use the shared events.jsonl as the transport layer. Fleet publishes `fleet.pattern.success` events containing extracted success metadata. Memory system reads these events during `memory_finalize_pipeline` and ingests them into `global.json` under a new `fleet_patterns` array with `source_repo` tags and `cross_repo_success_count` tracking.

**Alternatives rejected:**
- Separate pattern database: Over-engineered for append-only success data
- Direct file writes to peer repos: Already proven fragile in discovery_fleet_broadcast (needs filesystem access to all repos)
- WebSocket-based: No persistent server in fleet mode

**Consequences:** All repos must share the same events.jsonl (already true in fleet mode). Pattern storage grows linearly with unique success patterns (capped at 200 entries).

---

## Component Diagram

```
+-----------------------+     emit_event            +------------------+
|  pipeline-commands.sh | --------------------->    |  events.jsonl    |
|  (pipeline success)   |  "fleet.pattern.success"  |  (shared bus)    |
+-----------------------+                           +--------+---------+
                                                             |
         +---------------------------------------------------+
         | read on pipeline finalize
         v
+-----------------------+                           +------------------+
|   sw-memory.sh        |  writes fleet patterns    |  global.json     |
|   memory_ingest_fleet |  ---------------------->  |  .fleet_patterns |
|   _patterns()         |  with source_repo tag     |  [{source_repo,  |
+-----------------------+                           |   goal, count}]  |
                                                    +--------+---------+
         +---------------------------------------------------+
         | reads during injection
         v
+-----------------------+                           +------------------+
|   sw-memory.sh        |                           |  sw-fleet.sh     |
|   memory_inject_      |                           |  fleet_patterns  |
|   context() +boost    |                           |  _show() CLI     |
+-----------------------+                           +------------------+
                                                             |
                                                             v
                                                    +------------------+
                                                    |  dashboard/      |
                                                    |  server.ts       |
                                                    |  /api/fleet/     |
                                                    |  learning-stats  |
                                                    +------------------+
```

## Interface Contracts

```typescript
// Event: fleet.pattern.success (emitted to events.jsonl)
interface FleetPatternSuccessEvent {
  ts: string;           // ISO 8601
  type: "fleet.pattern.success";
  source_repo: string;  // e.g. "owner/repo-name"
  goal: string;         // pipeline goal (truncated to 200 chars)
  approach: string;     // stages passed, e.g. "intake,plan,build,test,review,pr"
  files_changed: number;
  test_strategy: string; // test runner from patterns.json
  duration_s: number;
  complexity: number;
  template: string;     // pipeline template used
  pattern_hash: string; // SHA256 of goal for dedup
}

// Storage: global.json .fleet_patterns[]
interface FleetPattern {
  pattern_hash: string;
  source_repo: string;       // first repo that succeeded
  goal: string;
  approach: string;
  template: string;
  test_strategy: string;
  complexity: number;
  avg_duration_s: number;
  cross_repo_success_count: number;  // incremented per unique repo
  repos_succeeded: string[];          // list of repos (max 20)
  first_seen: string;                 // ISO 8601
  last_seen: string;                  // ISO 8601
  adopted_count: number;              // times injected into other repos
}

// CLI output: shipwright fleet patterns --top N [--json]
// Dashboard endpoint: GET /api/fleet/learning-stats
interface FleetLearningStats {
  total_patterns: number;
  patterns_shared: number;     // unique patterns with count > 1
  patterns_adopted: number;    // patterns with adopted_count > 0
  success_lift_pct: number;    // % of adopted patterns vs total
  top_patterns: FleetPattern[];
}
```

## Data Flow

```
Pipeline success
  -> pipeline-commands.sh:pipeline_completed_handler (existing)
    -> emit_event "fleet.pattern.success" (NEW - only if fleet config exists)
      -> events.jsonl

Pipeline finalize (any repo in fleet)
  -> memory_finalize_pipeline() (existing)
    -> memory_ingest_fleet_patterns() (NEW)
      -> reads events.jsonl for fleet.pattern.success events
      -> deduplicates by pattern_hash
      -> increments cross_repo_success_count per unique source_repo
      -> writes to global.json .fleet_patterns[]

Memory injection (future pipeline in any repo)
  -> memory_inject_context() (existing, MODIFIED)
    -> reads global.json .fleet_patterns[]
    -> boosts relevance_score +10 for patterns with cross_repo_success_count > 3
    -> injects as "Fleet-proven patterns" section

CLI display
  -> shipwright fleet patterns [--top N] [--json]
    -> reads global.json .fleet_patterns[]
    -> sorts by cross_repo_success_count desc
    -> displays top N

Dashboard
  -> GET /api/fleet/learning-stats
    -> reads global.json .fleet_patterns[]
    -> computes aggregate stats
```

## Error Boundaries

| Component | Error | Handling |
|-----------|-------|----------|
| Event emission | events.jsonl missing/unwritable | `emit_event` already creates dir; failure is silent (|| true) |
| Pattern ingestion | Malformed event JSON | `jq` with `2>/dev/null` + `|| true`; skip malformed entries |
| Global.json write | Concurrent writers | Atomic tmp+mv; last writer wins (acceptable for counters) |
| Fleet config missing | Not in fleet mode | Guard: `[[ ! -f fleet-config.json ]]` -> skip broadcasting |
| Dashboard endpoint | global.json missing | Return `{total_patterns: 0, ...}` empty stats |

---

## Schema Changes

**global.json** — Add new top-level key `fleet_patterns` (additive, no migration needed):

```json
{
  "common_patterns": [],
  "cross_repo_learnings": [],
  "fleet_patterns": [
    {
      "pattern_hash": "a1b2c3...",
      "source_repo": "org/api-service",
      "goal": "Add rate limiting to /api/v2 endpoints",
      "approach": "intake,plan,build,test,review,pr",
      "template": "standard",
      "test_strategy": "vitest",
      "complexity": 45,
      "avg_duration_s": 1200,
      "cross_repo_success_count": 4,
      "repos_succeeded": ["org/api-service", "org/web-app", "org/cli-tool", "org/sdk"],
      "first_seen": "2026-04-01T10:00:00Z",
      "last_seen": "2026-04-03T15:30:00Z",
      "adopted_count": 7
    }
  ]
}
```

**Rollback:** Remove the `fleet_patterns` key from global.json. No other schema changes. Fully backward-compatible — existing code ignores unknown keys.

## Idempotency Strategy

- **Event dedup:** Pattern hash (SHA256 of normalized goal text) + source_repo. Same repo re-completing same goal updates `last_seen` but doesn't increment `cross_repo_success_count`.
- **Ingestion dedup:** `memory_ingest_fleet_patterns()` checks `pattern_hash` existence before insert. If exists, only updates count if `source_repo` is new in `repos_succeeded`.
- **Side-effect safety:** All writes are to local files via atomic tmp+mv. No external API calls. Safe to retry.

## Rollback Plan

1. Revert changes to `scripts/lib/pipeline-commands.sh` (remove fleet pattern emission)
2. Revert changes to `scripts/sw-memory.sh` (remove ingestion + priority boost)
3. Revert changes to `scripts/sw-fleet.sh` (remove `patterns` subcommand)
4. Revert changes to `dashboard/server.ts` (remove learning-stats endpoint)
5. Optionally clean global.json: `jq 'del(.fleet_patterns)' global.json`
6. No data loss — fleet_patterns is additive and ignored by existing code

---

## Files to Modify

| File | Change Type | Purpose |
|------|------------|---------|
| `scripts/lib/pipeline-commands.sh` | Modify (~20 lines) | Emit `fleet.pattern.success` event on pipeline success |
| `scripts/sw-memory.sh` | Modify (~150 lines) | Add `memory_ingest_fleet_patterns()`, modify `memory_inject_context()` boost, modify `memory_finalize_pipeline()` |
| `scripts/sw-fleet.sh` | Modify (~120 lines) | Add `fleet_patterns_show()` CLI command, wire into router |
| `dashboard/server.ts` | Modify (~50 lines) | Add `/api/fleet/learning-stats` endpoint |
| `scripts/sw-fleet-patterns-test.sh` | Create (~400 lines) | Test suite for fleet pattern broadcasting |

---

## Implementation Steps

### Step 1: Emit fleet.pattern.success event on pipeline success

**File:** `scripts/lib/pipeline-commands.sh` (after line 826)

After the existing `sw-memory.sh capture` call on success, add fleet pattern broadcasting:
- Check if `.claude/fleet-config.json` exists (fleet mode indicator)
- Extract pattern metadata: goal, stages passed, template, complexity, duration
- Compute `pattern_hash` as SHA256 of normalized goal text
- Read test_strategy from memory patterns.json if available
- Count files changed via `git diff --name-only` on the PR branch
- Emit `fleet.pattern.success` event with all metadata

### Step 2: Add fleet pattern ingestion to sw-memory.sh

**File:** `scripts/sw-memory.sh`

Add `memory_ingest_fleet_patterns()` function (~80 lines):
- Read `fleet.pattern.success` events from events.jsonl (last 7 days)
- For each event, check if `pattern_hash` exists in `global.json .fleet_patterns[]`
- If new: insert with `cross_repo_success_count=1`, `repos_succeeded=[source_repo]`
- If exists but source_repo is new: increment count, append to repos_succeeded (cap at 20)
- If exists and source_repo already counted: update `last_seen` only
- Cap fleet_patterns at 200 entries (keep highest count)
- Atomic write to global.json

### Step 3: Wire ingestion into memory_finalize_pipeline

**File:** `scripts/sw-memory.sh` (in `memory_finalize_pipeline()`, after step 3)

Add step 4: `memory_ingest_fleet_patterns 2>/dev/null || true`

### Step 4: Boost fleet patterns in memory_inject_context

**File:** `scripts/sw-memory.sh` (in `memory_inject_context()`)

For `build` and `plan` stages:
- Read `global.json .fleet_patterns[]` where `cross_repo_success_count > 3`
- Inject as a "Fleet-Proven Patterns" section with goal, approach, and success count
- These patterns get a +10 relevance boost in the ranking algorithm

### Step 5: Add fleet patterns CLI to sw-fleet.sh

**File:** `scripts/sw-fleet.sh`

Add `fleet_patterns_show()` function (~80 lines):
- Parse `--top N` (default 10) and `--json` flags
- Read `global.json .fleet_patterns[]`
- Sort by `cross_repo_success_count` descending
- Display formatted table or JSON output
- Show summary stats: total patterns, shared (count>1), adopted

Wire into command router: `patterns) fleet_patterns_show "$@" ;;`

### Step 6: Add dashboard learning-stats endpoint

**File:** `dashboard/server.ts`

Add handler for `GET /api/fleet/learning-stats`:
- Read global.json fleet_patterns array
- Compute: total_patterns, patterns_shared, patterns_adopted, success_lift_pct
- Return top 10 patterns sorted by cross_repo_success_count
- Handle missing file gracefully (return zeros)

### Step 7: Create test suite

**File:** `scripts/sw-fleet-patterns-test.sh` (new)

Test cases:
1. Fleet pattern event emission on pipeline success
2. Fleet pattern event NOT emitted when no fleet config
3. Pattern ingestion creates new entry in global.json
4. Pattern ingestion increments count for new source_repo
5. Pattern ingestion does NOT double-count same source_repo
6. Fleet patterns capped at 200 entries
7. Memory injection boosts fleet patterns with count > 3
8. CLI `fleet patterns` displays top patterns
9. CLI `fleet patterns --json` outputs valid JSON
10. CLI `fleet patterns` with empty global.json shows "no patterns"
11. Pattern hash deduplication works correctly
12. Atomic write safety (global.json not corrupted on concurrent write)

---

## Task Checklist

- [ ] Task 1: Add fleet pattern event emission to pipeline-commands.sh on success path
- [ ] Task 2: Add `memory_ingest_fleet_patterns()` function to sw-memory.sh
- [ ] Task 3: Wire ingestion into `memory_finalize_pipeline()` as step 4
- [ ] Task 4: Add fleet-proven pattern boost to `memory_inject_context()` for build/plan stages
- [ ] Task 5: Add `fleet_patterns_show()` CLI command to sw-fleet.sh with --top and --json flags
- [ ] Task 6: Wire `patterns` subcommand into sw-fleet.sh command router
- [ ] Task 7: Add `/api/fleet/learning-stats` endpoint to dashboard/server.ts
- [ ] Task 8: Create sw-fleet-patterns-test.sh with 12 test cases
- [ ] Task 9: Run test suite and fix any failures
- [ ] Task 10: Update sw-fleet.sh `show_help()` to document the new `patterns` subcommand

---

## Testing Approach

### Test Pyramid Breakdown

- **Unit tests (10 tests):** Pattern hash computation, event parsing, deduplication logic, count increment, cap enforcement, relevance boost calculation, JSON output formatting, empty-state handling, pattern_hash collision handling, atomic write verification
- **Integration tests (2 tests):** Full event emission -> ingestion -> global.json write cycle; Memory injection reads fleet patterns and includes them in context
- **E2E tests (0):** Not needed — the unit + integration tests cover the full data flow without requiring live Claude or GitHub

### Coverage Targets

- **Event emission path:** 100% — every branch (fleet config exists/missing, pattern data available/missing)
- **Ingestion logic:** 100% — new pattern, existing pattern + new repo, existing pattern + same repo, cap enforcement
- **CLI display:** 90% — formatted output, JSON output, empty state
- **Dashboard endpoint:** Covered by existing dashboard test patterns

### Critical Paths to Test

**Happy path:** Pipeline succeeds -> event emitted -> next pipeline finalizes -> pattern ingested -> future pipeline gets boosted injection

**Error case 1:** events.jsonl contains malformed JSON lines -> ingestion skips them, doesn't crash

**Error case 2:** global.json doesn't exist yet -> ingestion creates it with fleet_patterns array

**Edge case 1:** Same repo succeeds with same goal twice -> count stays at 1, last_seen updates

**Edge case 2:** 201st pattern arrives -> oldest/lowest-count pattern evicted to maintain cap of 200

---

## Definition of Done

- [ ] `fleet.pattern.success` events appear in events.jsonl after successful pipeline runs in fleet mode
- [ ] `global.json` contains `fleet_patterns[]` with `source_repo` tags after ingestion
- [ ] Patterns with `cross_repo_success_count > 3` get priority boost in memory injection
- [ ] `shipwright fleet patterns --top 10` displays fleet-wide success patterns
- [ ] `shipwright fleet patterns --json` outputs valid JSON
- [ ] Dashboard `/api/fleet/learning-stats` returns stats object
- [ ] All 12 test cases pass in `sw-fleet-patterns-test.sh`
- [ ] No existing tests broken (`npm test` passes)
- [ ] No fleet config -> no event emission (graceful degrade)
- [ ] Atomic writes used for all global.json modifications

---

## Failure Mode Analysis

### 1. Race Condition on global.json (Concurrency Risk) — CRITICAL

**What breaks:** Two repos finalize pipelines simultaneously, both read global.json, both write back. One write is lost.

**Likelihood:** Medium in active fleet (multiple daemons completing near-simultaneously).

**Mitigation:** Atomic writes via tmp+mv already handle partial writes. For counter accuracy, accept that last-writer-wins may undercount by 1 occasionally — this is acceptable for advisory data. The `repos_succeeded` array provides ground truth for recalculation if needed.

**Addressed in implementation:** Step 2 uses the standard `tmp_file=$(mktemp "${global_file}.tmp.XXXXXX"); jq ... > "$tmp_file" && mv "$tmp_file" "$global_file"` pattern consistently.

### 2. Event Log Bloat from High-Frequency Fleets (Scale Risk)

**What breaks:** Fleet with 50 repos, each completing 10 pipelines/day = 500 events/day. events.jsonl grows.

**Likelihood:** Low — even at scale, 500 JSON lines/day is ~50KB. The 7-day TTL cleanup in eventbus handles this.

**Mitigation:** Pattern events are small (~300 bytes each). The existing `eventbus clean` handles TTL. Fleet patterns in global.json are capped at 200 entries.

### 3. Stale/Irrelevant Pattern Injection (Runtime Risk)

**What breaks:** A Go repo receives success patterns from a Python repo. The pattern ("use pytest for testing") is irrelevant and wastes context tokens.

**Likelihood:** High in heterogeneous fleets.

**Mitigation:** Include `test_strategy` and project metadata in pattern events. During `memory_inject_context()`, filter fleet patterns by matching project type (node->node, go->go). Only inject patterns where the project type matches OR the pattern is project-agnostic (based on goal text). This is addressed in Step 4 — the injection filters by project type compatibility before boosting.
