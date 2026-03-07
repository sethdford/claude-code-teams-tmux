# Implementation Plan: Real-Time Intelligence Event Streaming to Active Pipelines

## Goal

Enable active pipelines to receive and react to intelligence events (predictions, anomalies, discoveries, model recommendations) in real-time, rather than only consuming intelligence data at stage boundaries. This creates a feedback loop where intelligence insights flow continuously into running pipelines, enabling mid-stage adaptation.

---

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change:** A streaming subscriber that runs alongside each pipeline, watches for intelligence events on the eventbus, and writes actionable insights to a file the pipeline/loop can consume between iterations.

**Implicit requirements:**

- Must not break existing pipeline flow (intelligence is currently consumed only at stage start)
- Must work with both SQLite-backed and JSONL-fallback eventbus
- Must be lightweight — no new daemons or heavy processes
- Must respect `$NO_GITHUB` and local mode

**Acceptance criteria:**

1. Intelligence events (predictions, anomalies, discoveries) are streamed to active pipelines in real-time
2. The build loop can consume mid-iteration intelligence signals
3. Events are filtered by relevance (pipeline ID, file patterns, stage)
4. Dashboard `/ws/events` streams intelligence events to connected clients
5. New `shipwright eventbus stream` subcommand for filtered real-time streaming
6. Test suite validates streaming, filtering, and consumption

### Alternatives Considered

**Approach A: Background subscriber process per pipeline**

- Spawn a background `eventbus subscribe` filtered to intelligence events
- Write matched events to `$ARTIFACTS_DIR/intelligence-stream.jsonl`
- Loop iterations read and consume this file
- _Pros:_ Simple, uses existing eventbus infrastructure, no new dependencies
- _Cons:_ Slight delay (poll interval), extra process per pipeline

**Approach B: Direct function call in pipeline loop**

- Add `poll_intelligence_events()` function called at each loop iteration
- Queries eventbus DB/file directly for new events since last check
- _Pros:_ No extra process, zero latency, simpler lifecycle
- _Cons:_ Tighter coupling, but uses existing patterns (like `inject_discoveries`)

**Approach C: Named pipe / FIFO**

- Create a named pipe that intelligence producers write to
- Pipeline reads non-blocking from the pipe
- _Pros:_ True real-time, zero-copy
- _Cons:_ Complex lifecycle management, platform differences, error-prone

**Chosen: Approach B** — Direct polling function. Minimizes blast radius (no new processes), reuses existing eventbus query infrastructure, follows the same pattern as `inject_discoveries()`. The poll function is called at iteration boundaries in the loop, keeping it non-intrusive.

### Risk Assessment

| Risk                                                 | Impact                                     | Mitigation                                                                                                |
| ---------------------------------------------------- | ------------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| Performance: polling on every iteration adds latency | Low — single SQLite query or grep is <10ms | Cache last-seen ID; skip if no new events                                                                 |
| Breaking existing pipelines                          | High                                       | New code is additive; guarded behind function existence checks (`type poll_intelligence >/dev/null 2>&1`) |
| Event flood overwhelming pipeline context            | Medium                                     | Hard limit on events per poll (10), prune to recent window, relevance filter                              |
| SQLite contention with concurrent writers            | Low                                        | SQLite WAL mode handles this; read-only queries don't block                                               |
| Eventbus not initialized                             | Low                                        | Graceful fallback — return empty when no events exist                                                     |

### Dependency Analysis

**Depends on:**

- `scripts/sw-eventbus.sh` — event storage and query infrastructure
- `scripts/sw-discovery.sh` — discovery broadcast/query pattern (we extend this)
- `scripts/lib/loop-iteration.sh` — where intelligence gets injected into build loops
- `scripts/lib/pipeline-intelligence.sh` — intelligence functions for pipeline
- `scripts/sw-intelligence.sh` — intelligence event emission
- `dashboard/server.ts` — WebSocket event streaming

**Depended on by:** Nothing new — all integration is additive via existing guard patterns.

---

## Files to Modify

### New Files

1. `scripts/lib/intelligence-stream.sh` — Core streaming/polling library (sourced by pipeline and loop)
2. `scripts/sw-intelligence-stream-test.sh` — Test suite

### Modified Files

3. `scripts/sw-eventbus.sh` — Add `stream` subcommand with intelligence filtering
4. `scripts/lib/loop-iteration.sh` — Integrate intelligence polling at iteration boundaries
5. `scripts/lib/pipeline-intelligence.sh` — Add `poll_intelligence_events()` and `consume_intelligence_stream()`
6. `scripts/sw-pipeline.sh` — Source the new library; emit richer intelligence events with pipeline context
7. `dashboard/server.ts` — Add `/api/intelligence/stream` SSE endpoint and intelligence-filtered WebSocket channel
8. `package.json` — Register the new test suite

---

## Implementation Steps

### Step 1: Create `scripts/lib/intelligence-stream.sh`

Core library providing:

```bash
# Poll for new intelligence events since last check
# Returns JSON array of relevant events
poll_intelligence_events() {
    local pipeline_id="$1"
    local last_seen_id="${2:-0}"
    local event_types="intelligence.,prediction.,discovery."
    # Query eventbus (SQLite or JSONL fallback)
    # Filter by type prefix match
    # Return max 10 events, update last_seen_id
}

# Format intelligence events into actionable context for pipeline injection
format_intelligence_context() {
    local events_json="$1"
    # Convert raw events to concise, structured guidance text
    # Group by category: predictions, anomalies, model recommendations, discoveries
}

# Write intelligence stream state (last_seen_id, counts)
save_stream_state() {
    local pipeline_id="$1"
    local last_seen_id="$2"
    # Atomic write to $ARTIFACTS_DIR/intelligence-stream-state.json
}

# Load stream state
load_stream_state() {
    local pipeline_id="$1"
    # Read from $ARTIFACTS_DIR/intelligence-stream-state.json
}
```

### Step 2: Add `stream` subcommand to `sw-eventbus.sh`

New `cmd_stream()` function that combines subscribe + intelligence filtering:

```bash
cmd_stream() {
    local filter="${1:-intelligence}"
    local pipeline_id="${2:-}"
    local format="${3:-json}"  # json or text
    # Filtered real-time stream with intelligence-specific formatting
    # Supports: intelligence.*, prediction.*, discovery.*
}
```

Add to the command router and help text.

### Step 3: Integrate polling into `lib/loop-iteration.sh`

At the top of each loop iteration (after the existing discovery injection at line ~136), add:

```bash
# Real-time intelligence event streaming
if type poll_intelligence_events >/dev/null 2>&1; then
    local _intel_state_file="${ARTIFACTS_DIR:-/tmp}/intelligence-stream-state.json"
    local _last_seen_id=0
    [[ -f "$_intel_state_file" ]] && _last_seen_id=$(jq -r '.last_seen_id // 0' "$_intel_state_file" 2>/dev/null || echo 0)

    local _intel_events
    _intel_events=$(poll_intelligence_events "${SHIPWRIGHT_PIPELINE_ID:-$$}" "$_last_seen_id" 2>/dev/null || echo "")

    if [[ -n "$_intel_events" && "$_intel_events" != "[]" ]]; then
        local _intel_context
        _intel_context=$(format_intelligence_context "$_intel_events" 2>/dev/null || echo "")
        if [[ -n "$_intel_context" ]]; then
            intel_stream_section="## Real-Time Intelligence Signals

${_intel_context}"
        fi
        # Update last seen ID
        local _new_last_id
        _new_last_id=$(echo "$_intel_events" | jq -r '.[-1].id // .[-1].ts_epoch // 0' 2>/dev/null || echo 0)
        save_stream_state "${SHIPWRIGHT_PIPELINE_ID:-$$}" "$_new_last_id" 2>/dev/null || true
    fi
fi
```

### Step 4: Enrich intelligence event emissions in `sw-pipeline.sh`

Add `pipeline_id` to all `emit_event "intelligence.*"` and `emit_event "stage.*"` calls so subscribers can filter by pipeline:

```bash
emit_event "stage.completed" \
    "issue=${ISSUE_NUMBER:-0}" \
    "stage=$id" \
    "pipeline_id=${SHIPWRIGHT_PIPELINE_ID:-}" \
    "duration_s=$stage_dur_s" \
    "result=success"
```

### Step 5: Add `poll_intelligence_events()` to `lib/pipeline-intelligence.sh`

Wire the library function into the pipeline intelligence module so it's available when pipeline-intelligence.sh is sourced.

### Step 6: Add intelligence stream SSE endpoint to `dashboard/server.ts`

```typescript
// GET /api/intelligence/stream — SSE endpoint for real-time intelligence events
if (pathname === "/api/intelligence/stream") {
  const pipelineId = url.searchParams.get("pipeline_id");
  // Stream intelligence.* and prediction.* events as SSE
  // Filter by pipeline_id if provided
}
```

Also enhance `broadcastNewEvents()` to tag intelligence events for the frontend.

### Step 7: Source the library in `sw-pipeline.sh`

Add source guard near the other library loads (around line 46):

```bash
# shellcheck source=lib/intelligence-stream.sh
[[ -f "$SCRIPT_DIR/lib/intelligence-stream.sh" ]] && source "$SCRIPT_DIR/lib/intelligence-stream.sh"
```

### Step 8: Create test suite `scripts/sw-intelligence-stream-test.sh`

Test cases:

- `poll_intelligence_events` returns empty when no events
- `poll_intelligence_events` returns filtered intelligence events
- `poll_intelligence_events` respects last_seen_id (no duplicates)
- `format_intelligence_context` produces structured output
- `save_stream_state` / `load_stream_state` round-trip
- `cmd_stream` in eventbus outputs filtered events
- Integration: loop iteration consumes streamed intelligence
- Edge: handles missing eventbus gracefully
- Edge: handles corrupt/empty state file

### Step 9: Register test in `package.json`

Add `sw-intelligence-stream-test.sh` to the test suites in package.json.

---

## Task Checklist

- [ ] Task 1: Create `scripts/lib/intelligence-stream.sh` with `poll_intelligence_events()`, `format_intelligence_context()`, `save_stream_state()`, `load_stream_state()`
- [ ] Task 2: Add `stream` subcommand to `scripts/sw-eventbus.sh` with intelligence-specific filtering
- [ ] Task 3: Source `intelligence-stream.sh` in `scripts/sw-pipeline.sh` and add pipeline_id to intelligence event emissions
- [ ] Task 4: Wire `poll_intelligence_events` into `scripts/lib/pipeline-intelligence.sh`
- [ ] Task 5: Integrate intelligence polling into `scripts/lib/loop-iteration.sh` at iteration boundaries
- [ ] Task 6: Add `/api/intelligence/stream` SSE endpoint to `dashboard/server.ts`
- [ ] Task 7: Create `scripts/sw-intelligence-stream-test.sh` test suite with 9+ test cases
- [ ] Task 8: Register test suite in `package.json`
- [ ] Task 9: Run full test suite and fix any regressions

---

## Testing Approach

1. **Unit tests** (`sw-intelligence-stream-test.sh`): Mock eventbus data, verify polling, filtering, formatting, and state management
2. **Integration**: Verify loop-iteration.sh consumes intelligence events when the library is sourced
3. **Regression**: Run existing `sw-eventbus-test.sh`, `sw-pipeline-test.sh`, `sw-loop-test.sh`, `sw-intelligence-test.sh` to ensure no breakage
4. **Manual**: `shipwright eventbus stream intelligence` should show live intelligence events

---

## Definition of Done

- [ ] `poll_intelligence_events()` returns only intelligence/prediction/discovery events, filtered by last_seen_id
- [ ] Build loop iterations receive real-time intelligence signals (not just at stage start)
- [ ] `shipwright eventbus stream` command works with type filtering
- [ ] Dashboard SSE endpoint streams intelligence events to connected clients
- [ ] All intelligence event emissions include pipeline_id for filtering
- [ ] New test suite passes with 9+ test cases covering core + edge cases
- [ ] Existing test suites (`eventbus`, `pipeline`, `loop`, `intelligence`) pass without regression
- [ ] No Bash 3.2 compatibility violations (no associative arrays, readarray, etc.)
- [ ] Atomic file writes for state persistence
- [ ] Graceful degradation when eventbus is unavailable

---

## Task Decomposition with Dependencies

1. **Task 1** (no deps): Create `scripts/lib/intelligence-stream.sh`
2. **Task 2** (no deps): Add `stream` subcommand to eventbus
3. **Task 3** (depends on Task 1): Source library in pipeline, enrich event emissions
4. **Task 4** (depends on Task 1): Wire into pipeline-intelligence.sh
5. **Task 5** (depends on Tasks 1, 4): Integrate into loop-iteration.sh
6. **Task 6** (no deps): Dashboard SSE endpoint
7. **Task 7** (depends on Tasks 1-5): Write test suite
8. **Task 8** (depends on Task 7): Register in package.json
9. **Task 9** (depends on all): Run full test suite

Tasks 1, 2, and 6 can be developed in parallel. Tasks 3-5 are sequential after Task 1.
