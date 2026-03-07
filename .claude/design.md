# Design: Real-Time Intelligence Event Streaming to Active Pipelines

## Context

Intelligence events (`intelligence.*`, `prediction.*`, `discovery.*`) are emitted throughout pipeline execution but are only consumed at **stage boundaries** — when `compose_prompt()` runs at the start of each loop iteration, it calls `inject_discoveries()` for cross-pipeline learnings. There is no mechanism for a running pipeline to receive intelligence signals (anomaly detections, risk predictions, model routing recommendations) mid-iteration or between stages.

**Constraints from the codebase:**

- The eventbus (`scripts/sw-eventbus.sh`) supports both SQLite (`~/.shipwright/shipwright.db`) and JSONL (`~/.shipwright/events.jsonl`) backends. SQLite uses WAL mode and tracks consumer offsets via `db_set_consumer_offset()`.
- Discovery injection in `scripts/lib/loop-iteration.sh` uses a guard pattern (`type inject_discoveries >/dev/null 2>&1`) — all new functionality must follow this same opt-in pattern.
- All bash scripts must be Bash 3.2 compatible (no associative arrays, no `readarray`, no `${var,,}`).
- The dashboard (`dashboard/server.ts`) already has `/ws/events` WebSocket streaming with `broadcastNewEvents()` that pushes events where `id > lastBroadcastEventId`, and a 2-second push interval.
- File writes must be atomic (tmp + `mv`). `emit_event()` appends to `$EVENTS_FILE` with `key=val` pairs.
- Pipeline context flows via `$SHIPWRIGHT_PIPELINE_ID` env var.

**Gap:** Intelligence producers (sw-intelligence.sh, sw-predictive.sh, sw-discovery.sh) emit 10+ event types to the eventbus, but the loop iteration prompt composer never reads them. The dashboard streams raw events to browser clients but doesn't filter by intelligence category. There is no CLI command to stream filtered intelligence events.

## Decision

**Approach: Direct polling at iteration boundaries** (no new background processes).

Add a `poll_intelligence_events()` function that queries the eventbus for new intelligence events since a tracked cursor, formats them into actionable context, and injects them into the loop iteration prompt alongside the existing discovery section. This mirrors the `inject_discoveries()` pattern already used in `compose_prompt()`.

### Component Diagram

```
                    +-----------------------+
                    |   Intelligence        |
                    |   Producers           |
                    | (sw-intelligence.sh,  |
                    |  sw-predictive.sh,    |
                    |  sw-discovery.sh)     |
                    +----------+------------+
                               |
                          emit_event()
                               |
                               v
                    +----------+------------+
                    |      Event Bus        |
                    |  (sw-eventbus.sh)     |
                    |  SQLite | JSONL       |
                    +----+-------+----------+
                         |       |
            +------------+       +-------------+
            |                                  |
            v                                  v
+-----------+-----------+      +---------------+---------+
| Intelligence Stream   |      |   Dashboard Server      |
| Library               |      |   (server.ts)           |
| (lib/intelligence-    |      |   /api/intelligence/    |
|  stream.sh)           |      |   stream (SSE)          |
| - poll_intelligence() |      |   /ws/events (filtered) |
| - format_context()    |      +-------------------------+
| - save/load_state()   |
+----------+------------+
           |
      sourced by
           |
           v
+----------+------------+
| Loop Iteration        |
| (lib/loop-iteration.sh|
|  compose_prompt())    |
| Injects as:           |
| "## Real-Time         |
|  Intelligence Signals"|
+-----------------------+
```

### Data Flow

```
1. Intelligence producer emits:
   emit_event "intelligence.analysis" "pipeline_id=issue-42" "complexity=high" ...

2. Event stored in eventbus:
   SQLite: events table (id, ts, ts_epoch, type, source, correlation_id, payload)
   JSONL:  ~/.shipwright/events.jsonl (one JSON line)

3. At loop iteration boundary, compose_prompt() calls:
   poll_intelligence_events("issue-42", last_seen_id=147)
     → Queries eventbus: SELECT * FROM events WHERE id > 147
         AND (type LIKE 'intelligence.%' OR type LIKE 'prediction.%' OR type LIKE 'discovery.%')
         ORDER BY id ASC LIMIT 10
     → Returns JSON array of matching events

4. format_intelligence_context(events_json)
     → Groups by category: predictions, anomalies, model recommendations
     → Returns concise markdown for prompt injection

5. Injected into prompt as "## Real-Time Intelligence Signals" section
   (after "## Cross-Pipeline Learnings", before architecture rules)

6. save_stream_state("issue-42", new_last_seen_id=153)
     → Atomic write to $ARTIFACTS_DIR/intelligence-stream-state.json

7. Dashboard SSE endpoint streams same events to browser clients:
   GET /api/intelligence/stream?pipeline_id=issue-42
     → Server-Sent Events with intelligence.* events filtered
```

### Interface Contracts

```bash
# --- scripts/lib/intelligence-stream.sh ---

# Poll for new intelligence events since last check.
# Args: pipeline_id (string), last_seen_id (integer, default 0)
# Returns: JSON array of event objects on stdout, empty "[]" if none
# Errors: Returns "[]" on any failure (graceful degradation)
# Side effects: None (read-only query)
poll_intelligence_events(pipeline_id, last_seen_id)

# Format raw events into concise, structured guidance text.
# Args: events_json (JSON array string from poll_intelligence_events)
# Returns: Markdown string on stdout grouped by category
# Errors: Returns "" on malformed input
# Side effects: None
format_intelligence_context(events_json)

# Persist stream cursor state atomically.
# Args: pipeline_id (string), last_seen_id (integer)
# Returns: 0 on success, 1 on failure
# Side effects: Writes $ARTIFACTS_DIR/intelligence-stream-state.json
save_stream_state(pipeline_id, last_seen_id)

# Load stream cursor state.
# Args: pipeline_id (string)
# Returns: last_seen_id (integer) on stdout, "0" if no state exists
# Errors: Returns "0" on any failure
# Side effects: None
load_stream_state(pipeline_id)


# --- scripts/sw-eventbus.sh (new subcommand) ---

# Stream filtered intelligence events in real-time.
# Args: filter (string, default "intelligence"), pipeline_id (string, optional),
#       format (string: "json"|"text", default "json")
# Returns: Continuous stream of matching events on stdout (one per line)
# Errors: Falls back to JSONL grep if SQLite unavailable
# Side effects: None
cmd_stream(filter, pipeline_id, format)


# --- dashboard/server.ts (new endpoint) ---

# SSE endpoint for real-time intelligence events.
# GET /api/intelligence/stream?pipeline_id=<id>
# Response: text/event-stream
#   data: {"type":"intelligence.analysis","ts":"...","payload":{...}}
# Filters: intelligence.*, prediction.*, discovery.* event types
# Auth: Same as existing endpoints (GitHub OAuth or local bypass)
```

```typescript
// --- dashboard/server.ts types ---

interface IntelligenceStreamEvent {
  type: string; // "intelligence.*" | "prediction.*" | "discovery.*"
  ts: string; // ISO 8601 timestamp
  ts_epoch: number; // Unix epoch seconds
  pipeline_id?: string; // Filter key
  payload: Record<string, string>; // key=val pairs from emit_event
}
```

### Error Boundaries

| Component                     | Error Source                           | Handling                          | Propagation                                                          |
| ----------------------------- | -------------------------------------- | --------------------------------- | -------------------------------------------------------------------- |
| `poll_intelligence_events`    | SQLite unavailable                     | Falls back to JSONL grep          | Returns `[]` — caller gets empty context                             |
| `poll_intelligence_events`    | JSONL file missing                     | Returns `[]`                      | No injection, loop continues normally                                |
| `format_intelligence_context` | Malformed JSON input                   | Returns `""`                      | No section added to prompt                                           |
| `save_stream_state`           | Write failure (disk full, permissions) | Logs warning, returns 1           | Next poll re-reads from old cursor (duplicates possible, idempotent) |
| `load_stream_state`           | Corrupt state file                     | Returns `0`                       | Re-reads all events (at most 10 due to LIMIT)                        |
| `cmd_stream` (eventbus)       | SQLite locked                          | Retries once, falls back to JSONL | Degraded output, no crash                                            |
| SSE endpoint                  | Client disconnect                      | Cleanup interval timer            | No server impact                                                     |
| SSE endpoint                  | No events match filter                 | Send keepalive comment every 15s  | Connection stays alive                                               |

All errors are **contained within the component that encounters them**. The loop iteration never fails due to intelligence streaming — every call site uses `2>/dev/null || true` or equivalent guards.

## Alternatives Considered

1. **Background subscriber process per pipeline** — Spawn a background `eventbus subscribe` filtered to intelligence events, write to `$ARTIFACTS_DIR/intelligence-stream.jsonl`, loop reads this file.
   - Pros: True real-time (sub-second), decoupled from loop timing
   - Cons: Extra process lifecycle management per pipeline, cleanup on crash/kill, risk of zombie processes in daemon mode, more complex than needed for iteration-boundary consumption

2. **Named pipe / FIFO** — Create a named pipe that intelligence producers write to, pipeline reads non-blocking.
   - Pros: True zero-latency streaming, zero-copy data transfer
   - Cons: Complex lifecycle (cleanup on crash, platform differences between macOS/Linux FIFO behavior), blocking reads require careful timeout handling, doesn't work well with the existing eventbus model, violates the Bash 3.2 compatibility constraints in practice

3. **Filesystem watch with inotifywait** — Watch `events.jsonl` for changes, trigger injection.
   - Pros: Event-driven, no polling overhead
   - Cons: `inotifywait` not available on macOS without Homebrew, adds external dependency, overkill for iteration-boundary reads that happen every few seconds anyway

**Why direct polling wins:** The loop already runs iterations every 10-60 seconds. Polling the eventbus at each iteration boundary adds <10ms of overhead (single indexed SQLite query). No new processes, no lifecycle management, no platform dependencies. Follows the exact same guard pattern as `inject_discoveries()`.

## Implementation Plan

### Files to create

- `scripts/lib/intelligence-stream.sh` — Core library (~120 lines): `poll_intelligence_events()`, `format_intelligence_context()`, `save_stream_state()`, `load_stream_state()`
- `scripts/sw-intelligence-stream-test.sh` — Test suite (~250 lines): 9+ test cases covering core + edge cases

### Files to modify

- `scripts/sw-eventbus.sh` — Add `stream` subcommand to command router (~40 lines added)
- `scripts/lib/loop-iteration.sh` — Add intelligence polling block after discovery injection in `compose_prompt()` (~20 lines added)
- `scripts/lib/pipeline-intelligence.sh` — Source the new library, expose `poll_intelligence_events` to pipeline context (~5 lines added)
- `scripts/sw-pipeline.sh` — Source `intelligence-stream.sh`, add `pipeline_id` to `emit_event` calls (~10 lines changed)
- `dashboard/server.ts` — Add `/api/intelligence/stream` SSE endpoint, filter intelligence events in `broadcastNewEvents()` (~60 lines added)
- `package.json` — Register `sw-intelligence-stream-test.sh` in test suites

### Dependencies

- No new external dependencies
- Uses existing: `jq`, `sqlite3` (optional), bash builtins

### Risk areas

- **`compose_prompt()` in `lib/loop-iteration.sh`** — This is the hot path for every loop iteration. The intelligence polling must be fast (<10ms) and never block. Mitigated by: LIMIT 10 on queries, `2>/dev/null || true` guards, cursor-based skip.
- **State file contention** — If multiple pipelines share the same `$ARTIFACTS_DIR` (shouldn't happen, but defensive). Mitigated by: pipeline_id in state file name, atomic writes.
- **Event volume** — A busy system could emit hundreds of intelligence events per minute. Mitigated by: hard cap of 10 events per poll, cursor advancement, relevance filtering by pipeline_id.
- **Dashboard SSE connection leaks** — Long-lived SSE connections that aren't cleaned up. Mitigated by: interval-based cleanup, keepalive pings.

## Validation Criteria

- [ ] `poll_intelligence_events()` returns `[]` when no events exist (graceful empty state)
- [ ] `poll_intelligence_events()` returns only `intelligence.*`, `prediction.*`, `discovery.*` event types
- [ ] `poll_intelligence_events()` respects `last_seen_id` — no duplicate events across calls
- [ ] `poll_intelligence_events()` works with both SQLite and JSONL backends
- [ ] `format_intelligence_context()` produces structured markdown grouped by category
- [ ] `save_stream_state()` / `load_stream_state()` round-trip correctly with atomic writes
- [ ] `load_stream_state()` returns `0` for missing or corrupt state files
- [ ] Loop iteration prompt includes `## Real-Time Intelligence Signals` section when events exist
- [ ] Loop iteration prompt is unchanged when no intelligence events exist (no empty sections)
- [ ] `shipwright eventbus stream` command outputs filtered intelligence events
- [ ] `shipwright eventbus stream` falls back to JSONL when SQLite is unavailable
- [ ] All `emit_event "intelligence.*"` calls in `sw-pipeline.sh` include `pipeline_id=`
- [ ] Dashboard SSE endpoint at `/api/intelligence/stream` streams events as `text/event-stream`
- [ ] Dashboard SSE endpoint filters by `pipeline_id` query parameter when provided
- [ ] Existing test suites pass without regression: `sw-eventbus-test.sh`, `sw-pipeline-test.sh`, `sw-loop-test.sh`, `sw-intelligence-test.sh`
- [ ] No Bash 3.2 compatibility violations (no associative arrays, `readarray`, `${var,,}`)
- [ ] All file writes use atomic tmp+mv pattern
