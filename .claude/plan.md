# Implementation Plan: Refactor sw-memory.sh into lib/ Modules

**Issue**: #3346  
**Goal**: Split sw-memory.sh into scripts/lib/daemon-*.sh Modules Beyond Existing Extraction  
**Status**: Plan Stage  
**Target**: Reduce sw-memory.sh from 2241 to <1500 lines via extraction

---

## Executive Summary

`sw-memory.sh` (2241 lines) mixes three distinct concerns:

1. **Pattern capture & cross-pipeline discovery** — failure patterns, pipeline learnings, fix tracking
2. **Cost tracking & DORA metrics** — deployment frequency, cycle time, change failure rate, MTTR
3. **Core memory operations** — semantic search, context injection, memory display

This plan extracts concerns 1 and 2 into focused lib/ modules while preserving all existing behavior and passing all tests unchanged.

---

## Component Diagram

```
                        ┌─────────────────────────────────────┐
                        │      sw-memory.sh (refactored)       │
                        │  ~1000 lines — core operations      │
                        │  • semantic search                  │
                        │  • memory injection                 │
                        │  • memory display CLI               │
                        └──────────────┬──────────────────────┘
                                       │
                ┌──────────────────────┼──────────────────────┐
                │                      │                      │
                ▼                      ▼                      ▼
    ┌────────────────────┐  ┌──────────────────┐  ┌───────────────────┐
    │ lib/memory-cost.sh │  │lib/memory-      │  │ lib/memory-       │
    │  ~400 lines        │  │discovery.sh     │  │ effectiveness.sh  │
    │                    │  │  ~650 lines     │  │  (existing)       │
    │ Cost tracking &    │  │                 │  │                   │
    │ DORA metrics:      │  │ Discovery &     │  │ Performance data  │
    │ • get_dora_...()   │  │ pattern capture │  │ • effectiveness   │
    │ • update_metrics() │  │ • capture_...() │  │   rates           │
    │ • get_baseline()   │  │ • record_...()  │  │ • fix outcomes    │
    │ • regression       │  │ • aggregate...()│  │                   │
    │   detection        │  │ • finalize...() │  │                   │
    └────────────────────┘  │ • query_fix...()│  └───────────────────┘
                             │ • from_log...()│
                             └─────────────────┘
                                       ▲
                                       │ sourced by
                                       │
                             ┌─────────────────────┐
                             │   Test Suites       │
                             │  (unchanged)        │
                             │ • sw-memory-test    │
                             │ • effectiveness-    │
                             │   test              │
                             └─────────────────────┘
```

---

## Interface Contracts

### lib/memory-cost.sh

**Module Guard**:

```bash
[[ -n "${_MEMORY_COST_LOADED:-}" ]] && return 0
_MEMORY_COST_LOADED=1
```

**Public Functions**:

```bash
# Get DORA metrics for a time window
# Input:  window_days (7), offset_days (0)
# Output: JSON {deploy_freq, cycle_time, cfr, mttr, total}
# Errors: Returns default zeros if events.jsonl not found
memory_get_dora_baseline(window_days: int, offset_days: int) -> JSON

# Get baseline value for a performance metric
# Input:  metric_name (string: "test_duration_s", "coverage_pct", etc.)
# Output: numeric baseline or empty string if not set
# Errors: Returns empty if metrics.json not found
memory_get_baseline(metric_name: string) -> string | empty

# Update a performance baseline and detect regressions
# Input:  metric_name, value (numeric)
# Output: none
# Errors: Returns 1 if metric_name or value empty
# Side effects: Emits event "memory.metric", warns on regression (>20%)
memory_update_metrics(metric_name: string, value: number) -> 0 | 1

# Internal: Compare metrics and flag regressions
# Used only by memory_update_metrics
_memory_check_regression(metric_name: string, previous: number, current: number) -> bool
```

**Preconditions**:

- `ensure_memory_dir()` must be called first (via caller)
- `repo_memory_dir()` must be available (from sw-memory.sh)
- `now_iso()` helper must be available

**Postconditions**:

- All writes are atomic (tmp file + mv)
- All jq operations use `--arg` for escaping
- Events emitted for observability

---

### lib/memory-discovery.sh

**Module Guard**:

```bash
[[ -n "${_MEMORY_DISCOVERY_LOADED:-}" ]] && return 0
_MEMORY_DISCOVERY_LOADED=1
```

**Public Functions**:

```bash
# Capture pipeline-level learnings from state file and artifacts
# Input:  state_file (path), artifacts_dir (path)
# Output: none
# Errors: Returns 1 if state_file not found
# Side effects: Writes to failures.json, appends to global.json cross_repo_learnings
memory_capture_pipeline(state_file: string, artifacts_dir: string) -> 0 | 1

# Capture and deduplicate failure patterns
# Input:  stage (string), error_output (text)
# Output: none
# Errors: Returns 0 if error_output empty, emits warning
# Side effects: Writes to failures.json with deduplication, dual-write to DB
memory_capture_failure(stage: string, error_output: string) -> 0

# Process error log into failures.json
# Input:  artifacts_dir (path containing error-log.jsonl)
# Output: none
# Errors: Returns 0 if error_log not found
# Side effects: Calls memory_capture_failure for each error entry
memory_capture_failure_from_log(artifacts_dir: string) -> 0

# Record whether a suggested fix was applied and resolved
# Input:  pattern_match (string), fix_applied (bool), fix_resolved (bool)
# Output: none
# Errors: Returns 1 if pattern not found or pattern_match empty
# Side effects: Updates fix_effectiveness_rate in failures.json
memory_record_fix_outcome(
    pattern_match: string,
    fix_applied: bool,
    fix_resolved: bool
) -> 0 | 1

# Convenience wrapper for fix tracking
# Input:  error_sig (string), success (bool)
# Output: none (returns 0 always)
# Errors: silently ignores empty error_sig
memory_track_fix(error_sig: string, success: bool) -> 0

# Find best matching fix for an error pattern
# Input:  error_pattern (regex string)
# Output: JSON {fix, fix_effectiveness_rate, seen_count, ...} or empty
# Errors: Returns empty if no match found
memory_query_fix_for_error(error_pattern: string) -> JSON | empty

# Get failures above a frequency threshold
# Input:  threshold (3 default — failures seen >= N times)
# Output: JSON array sorted by -seen_count, or []
# Errors: Returns [] if failures.json not found
memory_get_actionable_failures(threshold: int) -> JSON[]

# Promote high-frequency patterns to global memory
# Input:  none
# Output: none
# Errors: Returns 0 silently if failures not yet created
# Side effects: Appends to global.json, emits memory.global_aggregated event
_memory_aggregate_global() -> 0

# Orchestrate all finalization steps at pipeline completion
# Input:  state_file (path), artifacts_dir (path)
# Output: none
# Errors: Returns 0 silently if state_file not found
# Side effects: Calls capture_pipeline, capture_failure_from_log, aggregate_global
memory_finalize_pipeline(state_file: string, artifacts_dir: string) -> 0
```

**Preconditions**:

- `ensure_memory_dir()` must be called first
- `repo_memory_dir()` must be available
- `memory_capture_failure()` must be defined (exported from this module)
- Flock available on system (gracefully degrades to serial access if not)

**Postconditions**:

- All file writes atomic (tmp + mv)
- All jq operations use `--arg` for escaping
- Deduplication checked before adding new failures
- Fix effectiveness rate calculated correctly
- Events emitted for all state changes

---

## Data Flow

### Cost Tracking Flow

```
Pipeline completes
      │
      ▼
memory_update_metrics("test_duration_s", 1245)
      │
      ├─→ Read previous baseline from metrics.json
      │
      ├─→ Calculate regression threshold (>20%)
      │
      ├─→ Warn if regression detected
      │
      ├─→ Write new baseline (atomic: tmp → mv)
      │
      └─→ Emit "memory.metric" event
```

### Discovery & Pattern Capture Flow

```
Pipeline finishes
      │
      ▼
memory_finalize_pipeline(state_file, artifacts_dir)
      │
      ├─→ memory_capture_pipeline()
      │   ├─→ Parse pipeline state (status, goal, stages)
      │   ├─→ Record stage pass/fail
      │   └─→ Update global cross_repo_learnings
      │
      ├─→ memory_capture_failure_from_log()
      │   └─→ For each error in error-log.jsonl:
      │       └─→ memory_capture_failure(stage, error_text)
      │           ├─→ Deduplicate check
      │           ├─→ Create or increment failure entry
      │           └─→ Dual-write to DB
      │
      └─→ _memory_aggregate_global()
          └─→ Promote failures with seen_count ≥3 to global.json
```

### Fix Tracking & Query Flow

```
Build fails with error "Connection refused"
      │
      ▼
memory_track_fix("Connection refused", false)
  (calls memory_record_fix_outcome)
      │
      ├─→ Find matching failure pattern
      │
      ├─→ Update times_fix_suggested++
      │
      ├─→ Calculate fix_effectiveness_rate
      │
      └─→ Emit "memory.fix_outcome" event

---

Later: New build encounters same error
      │
      ▼
memory_query_fix_for_error("Connection refused")
      │
      ├─→ Search failures with pattern match
      │
      ├─→ Filter: fix_effectiveness_rate > 30%
      │
      ├─→ Return best match (highest effectiveness)
      │
      └─→ Return to caller for goal injection
```

---

## Error Boundaries

### lib/memory-cost.sh Error Handling

| Component                | Error Condition         | Handler                  | Output                   |
| ------------------------ | ----------------------- | ------------------------ | ------------------------ |
| memory_get_dora_baseline | events.jsonl missing    | Graceful                 | Return zeros JSON        |
| memory_update_metrics    | metric_name empty       | Reject                   | Return 1                 |
| memory_update_metrics    | Metrics file corruption | jq error, fallback       | Emit event, skip update  |
| memory_update_metrics    | File lock timeout       | Warn and skip            | Emit event, return 1     |
| _memory_check_regression | Math calculation error  | Default to no regression | Silently skip comparison |

**Error Propagation**: All errors are **contained**. Callers always get a predictable result (zeros, empty, or 1) without stack traces.

### lib/memory-discovery.sh Error Handling

| Component                       | Error Condition         | Handler            | Output               |
| ------------------------------- | ----------------------- | ------------------ | -------------------- |
| memory_capture_pipeline         | state_file missing      | Reject             | Return 1, warn       |
| memory_capture_failure          | error_output empty      | Reject             | Return 0, warn       |
| memory_capture_failure          | flock unavailable       | Degrade gracefully | Use serial access    |
| memory_capture_failure          | jq parse error          | Skip entry         | Emit event, continue |
| memory_record_fix_outcome       | pattern not found       | Warn               | Return 1             |
| memory_capture_failure_from_log | error-log.jsonl missing | Graceful           | Return 0, silent     |
| memory_query_fix_for_error      | failures.json corrupted | Return empty       | Safe fallback        |

**Error Propagation**: Most discovery errors are silently skipped (graceful degradation). Critical path errors (missing state file) return 1 and warn.

---

## Failure Mode Analysis

### Failure Mode 1: Circular Dependencies on Extraction

**Scenario**: Extract memory_capture_failure to memory-discovery.sh, but it calls `memory_store_for_embedding()` which remains in sw-memory.sh. If memory-discovery.sh sources sw-memory.sh, circular dependency results.

**Impact**: Script fails to source, pipeline halts.

**Mitigation**:

- Keep `memory_store_for_embedding()` in sw-memory.sh (it's optional/fallback)
- memory-discovery.sh calls it via `type memory_store_for_embedding >/dev/null 2>&1` check
- Falls back to silence if not available (graceful degradation)
- Verified: `memory_store_for_embedding` is only called from discovery code as optional logging

### Failure Mode 2: File Lock Contention During Concurrent Writes

**Scenario**: Two pipeline stages finish simultaneously and both call `memory_capture_failure()` on overlapping error patterns. Lock timeout occurs.

**Impact**: One or both updates are lost; failures.json may be corrupted.

**Mitigation**:

- Use proper `flock -w 10` with trap for cleanup (already in code)
- Atomic writes: tmpfile + mv pattern (already in code)
- If lock unavailable (older systems), degrade to serial: single agent per repo
- Configurable lock timeout: emit_event when timeout occurs, pipeline continues
- Test suite includes concurrent write scenario

### Failure Mode 3: Memory Injection During Test Failures

**Scenario**: Test suite calls `memory_capture_failure()` during mock pipeline. Global memory or repo-specific memory becomes polluted with test data. Subsequent real pipelines inject bad fixes.

**Impact**: Production builds fail with bogus memory-injected context.

**Mitigation**:

- Memory root: `$HOME/.shipwright/memory` (system-wide, not repo-local)
- Test suite uses `MEMORY_ROOT=/tmp/test-memory-xyz` override
- repo_hash() returns "test-repo" when in test mode (check git dir)
- Existing tests already use this pattern (verified in test files)
- New lib modules inherit the pattern automatically

### Failure Mode 4: Regression Detection False Positives

**Scenario**: metric "test_duration_s" varies naturally (1200s one day, 1300s next). 20% threshold triggers false warning on every other run.

**Impact**: Teams ignore legitimate regression warnings → real performance degradation goes unnoticed.

**Mitigation**:

- Threshold is 20%, which requires 240s jump (reasonable for ~1200s baseline)
- Only warn on _increase_, not decrease
- Effectiveness metrics tracked separately (fix_effectiveness_rate)
- Callers can adjust threshold via memory_update_metrics config
- Test suite includes both positive and negative regression scenarios

### Failure Mode 5: Cross-Repo Learning Pollution

**Scenario**: Org deploys fix for bug in Repo A. Fix is aggregated to global.json. Repo B encounters superficially similar pattern (different root cause) and injects the wrong fix from global memory.

**Impact**: Injected fix makes problem worse; introduces new bugs.

**Mitigation**:

- Aggregation requires `seen_count >= 3` (domain-specific patterns only)
- Each global pattern includes `source` field ("aggregate" vs. "manual")
- injection respects `source` and weights by `fix_effectiveness_rate`
- Patterns tagged by `category` (test, deploy, auth, etc.)
- Design decision recorded: don't auto-inject global fixes without category match
- Test suite includes cross-repo pattern scenarios

---

## Task Decomposition

### Phase 1: Preparation (Tasks 1-2)

- [ ] Task 1: Analyze sw-memory.sh function dependencies — map which functions call which, identify extraction boundaries
- [ ] Task 2: Review existing test suites (sw-memory-test.sh, sw-memory-effectiveness-test.sh) to understand coverage and ensure tests remain unchanged

### Phase 2: Extract lib/memory-cost.sh (Tasks 3-4)

- [ ] Task 3: Create scripts/lib/memory-cost.sh skeleton with module guard and function stubs for: memory_get_baseline(), memory_update_metrics(), memory_get_dora_baseline()
- [ ] Task 4: Move DORA and cost-tracking functions to memory-cost.sh; update sw-memory.sh to source and delegate

### Phase 3: Extract lib/memory-discovery.sh (Tasks 5-6)

- [ ] Task 5: Create scripts/lib/memory-discovery.sh skeleton; move discovery functions: memory_capture_pipeline(), memory_capture_failure(), memory_capture_failure_from_log(), memory_record_fix_outcome(), memory_track_fix(), memory_query_fix_for_error(), _memory_aggregate_global(), memory_finalize_pipeline()
- [ ] Task 6: Update sw-memory.sh to source memory-discovery.sh and delegate; ensure backward-compatible function signatures

### Phase 4: Integration & Validation (Tasks 7-9)

- [ ] Task 7: Run sw-memory-test.sh and verify all tests pass unchanged
- [ ] Task 8: Run sw-memory-effectiveness-test.sh and verify all tests pass unchanged
- [ ] Task 9: Run full npm test to ensure no regressions across the entire test suite

### Phase 5: Code Review & Cleanup (Tasks 10-12)

- [ ] Task 10: Verify sw-memory.sh line count dropped below 1500 lines
- [ ] Task 11: Update any documentation or references in .claude/CLAUDE.md (AUTO:core-scripts table)
- [ ] Task 12: Verify no circular dependencies by manually sourcing each module in isolation

---

## Testing Approach

### Test Strategy

**Unit Tests** (Existing, must pass unchanged):

- `sw-memory-test.sh` — 898 lines, tests all memory functions
- `sw-memory-effectiveness-test.sh` — 495 lines, tests fix outcome tracking

**Integration Tests** (Verify extraction doesn't break):

- Source lib/memory-cost.sh in isolation, call each function
- Source lib/memory-discovery.sh in isolation, call each function
- Source sw-memory.sh after extraction, verify all public functions still available
- Call chained functions (e.g., memory_finalize_pipeline → capture_pipeline → capture_failure)

**Regression Tests**:

- Run `npm test` (full suite) — all 102 test suites must pass
- Specifically run: sw-memory-test, sw-memory-effectiveness-test, sw-memory-discovery-test (if added), sw-memory-cost-test (if added)

**Manual Testing**:

- Trigger a real pipeline run, verify memory capture works end-to-end
- Check that failures.json is populated correctly
- Verify DORA metrics are calculated
- Confirm no duplicate error patterns in memory

### Definition of Done

✓ **Code Changes**:

- [ ] scripts/lib/memory-cost.sh created with all cost-tracking functions
- [ ] scripts/lib/memory-discovery.sh created with all discovery functions
- [ ] sw-memory.sh sources both new modules and delegates to them
- [ ] All existing public function signatures unchanged (backward compatible)
- [ ] No behavior change — pure extraction

✓ **Line Count**:

- [ ] sw-memory.sh reduced to < 1500 lines (target ~1000)
- [ ] lib/memory-cost.sh ~400 lines
- [ ] lib/memory-discovery.sh ~650 lines

✓ **Testing**:

- [ ] sw-memory-test.sh passes unchanged (all tests pass)
- [ ] sw-memory-effectiveness-test.sh passes unchanged
- [ ] npm test passes (all 102 suites)
- [ ] No new test files required; extraction doesn't change testability

✓ **Architecture**:

- [ ] No circular dependencies (verified by sourcing in isolation)
- [ ] Each module has clear single responsibility
- [ ] All module guards in place (_*_LOADED variables)
- [ ] Error handling consistent with existing patterns

✓ **Documentation**:

- [ ] Update .claude/CLAUDE.md AUTO:core-scripts table if line counts changed
- [ ] Module header comments document sourcing requirements
- [ ] No user-facing documentation changes needed (internal refactor)

---

## Alternatives Considered

### Alternative 1: Extract Only to lib/memory-cost.sh (Single Module)

**Approach**: Move only DORA/metrics to lib/memory-cost.sh, leave discovery in sw-memory.sh

**Pros**:

- Simpler extraction (fewer files, fewer dependencies)
- Smaller scope, lower risk

**Cons**:

- sw-memory.sh still >1700 lines (doesn't meet <1500 target)
- Mixing discovery and core concerns still violates separation principle
- Harder to test discovery functions in isolation
- Next refactor will still be needed for discovery

**Decision**: Rejected. The issue explicitly calls for both cost-tracking AND cross-pipeline-discovery extraction. Single module leaves too much debt.

---

### Alternative 2: Extract to Three Modules (Split Discovery Further)

**Approach**:

- lib/memory-cost.sh (DORA, metrics)
- lib/memory-discovery-failures.sh (capture, aggregate)
- lib/memory-discovery-fixes.sh (fix tracking, query)

**Pros**:

- Even finer-grained separation
- Fix tracking could be tested completely separately

**Cons**:

- More files = more complexity, more sourcing overhead
- fix tracking depends heavily on failure patterns (circular dependency)
- Overkill for current scale (650 lines total for discovery)
- Makes tests more complex (3 test files instead of 1)

**Decision**: Rejected. Two modules achieves clean separation without over-engineering. Three modules creates coupling between memory-discovery-fixes.sh and memory-discovery-failures.sh (not independent).

---

### Alternative 3: Extract to lib/daemon-memory-*.sh Prefix

**Approach**: Name modules lib/daemon-memory-cost.sh, lib/daemon-memory-discovery.sh (matching daemon-* pattern)

**Pros**:

- Consistent with lib/daemon-dispatch.sh, lib/daemon-poll.sh naming
- Signals that these are memory sub-components

**Cons**:

- Confusing: memory system is used by pipeline, intelligent agents, not just daemon
- Naming suggests these are daemon-specific (they're not)
- Harder to discover (grep "memory" won't find daemon-memory-*)

**Decision**: Rejected in favor of lib/memory-*.sh. Memory system is orthogonal to daemon; should have clear identity in filenames.

---

## Addressing Previous Failure Patterns

**From intelligence analysis** (failures.json): No previous similar refactoring was attempted on sw-memory.sh specifically. However:

1. **Previous sw-loop.sh refactor** (#3240) teaches: Large monolithic scripts benefit from lib/ extraction. The pattern works.
2. **Guard variables**: Use `_MODULE_LOADED=1` guard to prevent double-sourcing (proven pattern in lib/daemon-dispatch.sh).
3. **Atomic writes**: Existing code already uses tmpfile + mv pattern; new code inherits this.
4. **Testing approach**: Existing test suites already mock memory paths; new lib modules need no test setup changes.

---

## Implementation Notes

### Sourcing Order in sw-memory.sh

After extraction, sw-memory.sh sources:

```bash
# lib dependencies (existing)
source "$SCRIPT_DIR/lib/helpers.sh"

# new lib modules (extracted)
source "$SCRIPT_DIR/lib/memory-cost.sh"       # Cost tracking
source "$SCRIPT_DIR/lib/memory-discovery.sh"   # Pattern capture
```

These modules may call back to sw-memory.sh helpers (e.g., `repo_hash()`, `ensure_memory_dir()`), so they're **not** self-contained. This is intentional and mirrors lib/daemon-dispatch.sh which depends on sw-daemon.sh context.

### Backward Compatibility

All function signatures remain identical. Callers don't know or care whether a function is implemented in sw-memory.sh or lib/*.sh. Test suites don't change.

### Migration Path

If a future need arises to move memory operations to a separate daemon or agent, the extracted lib/ modules make this trivial:

- lib/memory-cost.sh and lib/memory-discovery.sh are self-contained enough to `source` elsewhere
- Reduces coupling between sw-memory.sh and sw-daemon.sh

---

## Risk Assessment & Mitigation

| Risk                                 | Likelihood | Impact                   | Mitigation                                                      |
| ------------------------------------ | ---------- | ------------------------ | --------------------------------------------------------------- |
| File lock contention                 | Medium     | Data loss                | Use flock with timeout, atomic writes, test concurrent access   |
| Test pollution from memory           | Low        | Production bug injection | Override MEMORY_ROOT in tests (already done)                    |
| Circular dependency                  | Low        | Script failure           | Verify sourcing order, manually test isolation                  |
| Performance regression               | Very Low   | Slower pipeline startup  | Module guards prevent re-sourcing; no functional overhead       |
| Regression detection false positives | Medium     | Warning fatigue          | 20% threshold reasonable, test both positive and negative cases |

---

## Effort Estimate

- **Phase 1 (Analysis)**: 30 min
- **Phase 2 (Cost extraction)**: 45 min
- **Phase 3 (Discovery extraction)**: 60 min
- **Phase 4 (Testing & validation)**: 45 min
- **Phase 5 (Cleanup & review)**: 30 min
- **Total**: ~3.5 hours

---

## Files to Modify/Create

| File                                    | Action    | Impact                                                                   |
| --------------------------------------- | --------- | ------------------------------------------------------------------------ |
| scripts/sw-memory.sh                    | Modify    | Remove extracted functions, add sources, reduce from 2241 to ~1000 lines |
| scripts/lib/memory-cost.sh              | Create    | New 400-line module for DORA/metrics                                     |
| scripts/lib/memory-discovery.sh         | Create    | New 650-line module for capture/discovery                                |
| scripts/sw-memory-test.sh               | No change | Tests pass unchanged (verify)                                            |
| scripts/sw-memory-effectiveness-test.sh | No change | Tests pass unchanged (verify)                                            |
| .claude/CLAUDE.md                       | Update    | Update AUTO:core-scripts table with new line counts                      |

---

## Success Metrics

1. ✓ sw-memory.sh < 1500 lines (target: ~1000)
2. ✓ All existing tests pass unchanged
3. ✓ No circular dependencies
4. ✓ Zero behavior change (verified via test suite)
5. ✓ Memory-cost and memory-discovery modules independently sourceable
