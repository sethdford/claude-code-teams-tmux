# Implementation Plan: Memory System Performance Optimization with Query Index & Cache Layer

**Pipeline Goal:** Memory System Performance Optimization with Query Index & Cache Layer  
**Issue:** #671  
**Generated:** 2026-06-19  
**Complexity:** Medium

---

## Executive Summary

The Shipwright memory system (`sw-memory.sh`) currently performs linear scans of JSON files for every query without caching. This causes:

- **Latency:** Query times scale linearly with memory file size (100-500ms for typical queries)
- **CPU usage:** Repeated identical queries perform redundant work
- **Daemon impact:** Frequent memory queries during pipeline runs degrade overall throughput

This plan introduces a **tiered caching layer** with **lazy indexing** to reduce query latency by 50-70% while maintaining backward compatibility and data integrity.

---

## Requirements Clarity (Self-Answered)

### What is the minimum viable change?

Add indexing for fast lookups and caching for repeated queries to the existing memory system without breaking backward compatibility.

### Implicit Requirements

- **Backward Compatibility:** Existing memory format remains unchanged on disk
- **Concurrency Safety:** Handle multiple agents querying memory simultaneously
- **Cache Invalidation:** Automatically invalidate cache when memory files change
- **Data Integrity:** No data loss or corruption during index/cache operations
- **Performance Metrics:** Measure and report performance improvements

### Acceptance Criteria (Defined)

- [ ] Query latency reduced by ≥50% for typical searches (target: <100ms)
- [ ] Cache hit ratio ≥70% for daemon-driven workloads
- [ ] All existing memory tests pass (100% backward compatibility)
- [ ] New index/cache modules have comprehensive tests
- [ ] Memory data integrity verified after cache operations
- [ ] Index rebuild doesn't block queries (lazy/background process)
- [ ] Cache eviction prevents unbounded growth (LRU, TTL)

---

## Design Alternatives Considered

### **Alternative 1: In-Memory LRU Cache Only** (REJECTED)

```
Query → Check memory LRU cache → Cache hit: return
                              → Cache miss: search memory files → Add to LRU → return
```

**Pros:**

- Simplest implementation
- Zero persistence overhead

**Cons:**

- Lost on daemon restart (all cache flushed)
- No help across different daemon sessions
- For daemons with long runtimes, this is adequate but suboptimal

**Blast Radius:** Small (1-2 new functions)

**Trade-off:** Simple but leaves performance gains on table after restart.

---

### **Alternative 2: SQLite Full-Text Search Migration** (REJECTED)

```
Migrate memory JSON → SQLite tables → Use FTS5 → Native indexing + persistence
```

**Pros:**

- Most powerful query engine
- Native full-text search
- Persistent cache in DB

**Cons:**

- Major refactoring: changes memory storage format
- Migration complexity for existing installations
- Risk of data loss during migration
- Breaking change for scripts reading memory files directly
- Higher implementation complexity

**Blast Radius:** Large (touches memory storage format, multiple scripts)

**Trade-off:** Powerful but high risk for a relatively straightforward optimization.

---

### **Alternative 3: Hybrid Index + SQLite Cache Layer** (CHOSEN ✓)

```
Memory files (unchanged) → Fast JSON index (in-memory map) → SQLite query cache
                       ↓ Write-through on changes
                    .shipwright/cache/ (TTL + LRU)
```

**Pros:**

- Leverages existing `sw-db.sh` (SQLite layer already in codebase)
- Maintains JSON format (zero breaking changes)
- Fast in-memory index + persistent cache gives best of both worlds
- Incremental: can add FTS5 layer later without rework
- Lazy indexing: doesn't block on startup

**Cons:**

- Slightly more complex than LRU-only
- Requires cache invalidation logic
- Multiple layers to debug

**Blast Radius:** Moderate (2 new modules, minimal changes to sw-memory.sh)

**Trade-off:** Best balance of speed, maintainability, and safety.

---

## Architecture Overview

### Three-Layer Design

```
┌─────────────────────────────────────────────────────┐
│ Query Interface (memory_ranked_search)              │
│ • Entry point unchanged (backward compatible)       │
└───────────────┬─────────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────┐
│ Cache Layer (lib/memory-cache.sh) — NEW            │
│ • Check SQLite query cache (TTL/LRU)                │
│ • Return if hit; else proceed to index layer        │
└───────────────┬─────────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────┐
│ Index Layer (lib/memory-index.sh) — NEW            │
│ • Fast keyword→file-location map (in-memory JSON)   │
│ • Rebuild on file mtime change (lazy, background)   │
└───────────────┬─────────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────┐
│ Search Engine (sw-memory.sh) — MODIFIED            │
│ • Existing TF-IDF keyword scoring (unchanged)       │
│ • Process indexed entries instead of all entries    │
└─────────────────────────────────────────────────────┘
```

### Data Structures

**Memory Index (JSON, in-memory, built on demand):**

```json
{
  "failures": {
    "keyword1": [0, 5, 12], // line numbers in failures.json
    "keyword2": [3, 8]
  },
  "decisions": {
    "keyword1": [1, 7],
    "keyword3": [0]
  },
  "patterns": {
    "all_keys": true // patterns.json is always full-text searched
  },
  "metadata": {
    "failures_mtime": 1624051234,
    "decisions_mtime": 1624051200,
    "patterns_mtime": 1624051100,
    "index_built_at": 1624051235
  }
}
```

**Query Cache (SQLite table):**

```sql
CREATE TABLE IF NOT EXISTS memory_query_cache (
  query_hash TEXT PRIMARY KEY,      -- SHA-256 of normalized query
  query TEXT NOT NULL,              -- original query string
  results TEXT NOT NULL,            -- JSON array of results
  cache_key TEXT,                   -- memory_dir hash for multi-repo
  created_at INTEGER,               -- timestamp
  last_accessed_at INTEGER,
  hit_count INTEGER DEFAULT 0,      -- for LRU eviction
  ttl_seconds INTEGER DEFAULT 3600
);
```

---

## Task Decomposition with Dependencies

### Phase 1: Foundation (No dependencies)

**Task 1: Create lib/memory-index.sh module**

- Build JSON keyword index from memory files
- Detect file changes via mtime tracking
- Lazy rebuild mechanism (rebuild if any file changed)
- Checksum validation to prevent corruption
- Dependency: `scripts/lib/helpers.sh`, `scripts/lib/compat.sh`

**Task 2: Create lib/memory-cache.sh module**

- Implement query result caching with TTL/LRU
- Use SQLite for persistence (delegate to sw-db.sh)
- Query result hashing for cache keys
- Cache invalidation on memory write
- Dependency: `scripts/sw-db.sh`, `scripts/lib/helpers.sh`

### Phase 2: Integration (Depends on Phase 1)

**Task 3: Modify sw-memory.sh — Add cache checking**

- Before search: check cache layer
- After search: populate cache layer
- Add write-through on memory_save operations
- Dependency: Task 1, Task 2

**Task 4: Modify sw-memory.sh — Use index for filtering**

- Integrate index layer into search flow
- Process only indexed entries instead of full files
- Measure performance improvements
- Dependency: Task 1, Task 3

### Phase 3: Safety & Observability

**Task 5: Add index validation & self-healing**

- Periodic index integrity checks
- Auto-rebuild on corruption detection
- Checksums for confidence
- Dependency: Task 1

**Task 6: Add cache management functions**

- `memory_cache_info` — Show cache stats
- `memory_cache_clear` — Manual purge
- `memory_cache_prune` — LRU/TTL eviction
- Dependency: Task 2

**Task 7: Add metrics & monitoring**

- Track cache hit rate per query type
- Measure query latency (before/after cache)
- Log cache performance to events.jsonl
- Dependency: Task 2, Task 3

### Phase 4: Testing

**Task 8: Create lib/memory-index-test.sh**

- Unit tests for index building
- Test lazy rebuild on file changes
- Test checksum validation
- Dependency: Task 1

**Task 9: Create lib/memory-cache-test.sh**

- Unit tests for cache hit/miss
- Test TTL expiration
- Test LRU eviction
- Dependency: Task 2

**Task 10: Modify sw-memory-test.sh**

- Add integration tests for cached queries
- Verify cache hit rate ≥70%
- Verify latency reduction ≥50%
- Test backward compatibility
- Dependency: Task 3, Task 4, Task 8, Task 9

### Phase 5: Documentation & Cleanup

**Task 11: Update inline comments & function docs**

- Document cache/index architecture
- Add perf notes (expected latency improvements)
- Dependency: Task 3, Task 4

**Task 12: Update CLAUDE.md AUTO:core-scripts section**

- Document new lib/memory-index.sh
- Document new lib/memory-cache.sh
- Note performance improvements
- Dependency: Task 11

---

## Implementation Details

### Task 1: lib/memory-index.sh

**Key Functions:**

```bash
# Build in-memory index of memory files (called lazily)
memory_index_build() {
  local memory_dir="$1"
  # 1. Check if any memory file newer than last index build
  # 2. If stale, rebuild from scratch:
  #    a. For failures.json: index each failure's keywords
  #    b. For decisions.json: index each decision's keywords
  #    c. For patterns.json: mark for full-text (too unstructured)
  # 3. Store index in temp file, atomic mv to .shipwright/cache/memory-index.json
  # 4. Return index object
}

# Check if index is fresh
memory_index_is_fresh() {
  local memory_dir="$1"
  # Compare mtime of failures.json, decisions.json, patterns.json
  # against metadata.*.mtime in index
  # Return 0 if all files unchanged, 1 if rebuild needed
}

# Get index (build if stale)
memory_index_get() {
  local memory_dir="$1"
  if memory_index_is_fresh "$memory_dir"; then
    cat .shipwright/cache/memory-index.json
  else
    memory_index_build "$memory_dir"
  fi
}

# Find matching entries by keyword
memory_index_lookup() {
  local index="$1" keyword="$2" category="$3"  # category: failures|decisions|patterns
  # Use jq to extract line numbers from index[category][keyword]
  # Return array of matching entry indices
}
```

---

### Task 2: lib/memory-cache.sh

**Key Functions:**

```bash
# Initialize cache table in SQLite
memory_cache_init() {
  # Create table if not exists (uses db_execute from sw-db.sh)
  # Set default TTL to 3600 seconds
}

# Check cache for query result
memory_cache_get() {
  local query="$1" memory_dir="${2:-}"
  local query_hash
  query_hash=$(echo -n "$query:$memory_dir" | sha256sum | cut -d' ' -f1)

  # Query SQLite:
  # SELECT results FROM memory_query_cache
  # WHERE query_hash = ? AND created_at + ttl_seconds > now()
  # If found: UPDATE last_accessed_at, increment hit_count
  #          return results
  # If not found: return empty (cache miss)
}

# Store result in cache
memory_cache_set() {
  local query="$1" results="$2" memory_dir="${3:-}" ttl="${4:-3600}"
  local query_hash
  query_hash=$(echo -n "$query:$memory_dir" | sha256sum | cut -d' ' -f1)

  # INSERT OR REPLACE INTO memory_query_cache
  # Handle concurrent writes atomically
}

# Get cache statistics
memory_cache_stats() {
  # SELECT count(*), sum(hit_count), avg(hit_count)
  # FROM memory_query_cache WHERE created_at + ttl > now()
  # Return JSON: {total: N, hits: N, hit_rate: %, oldest: timestamp}
}

# Evict expired/LRU entries
memory_cache_prune() {
  # DELETE entries where created_at + ttl < now()
  # DELETE top-K LRU entries (by hit_count) to stay under size limit
  # Log eviction stats
}
```

---

### Task 3: Modify sw-memory.sh — Cache Integration

**In `memory_ranked_search()` function:**

```bash
memory_ranked_search() {
    local query="$1"
    local memory_dir="$2"
    local max_results="${3:-5}"

    # NEW: Check cache first
    local cached_result
    if cached_result=$(memory_cache_get "$query" "$memory_dir" 2>/dev/null); then
        [[ -n "$cached_result" ]] && echo "$cached_result" && return 0
    fi

    # Existing search logic (unchanged)...
    # ... process query, build results ...

    # NEW: Cache the result before returning
    local results="$output"
    memory_cache_set "$query" "$results" "$memory_dir" 3600 2>/dev/null || true

    echo "$output"
}
```

**Add write-through invalidation:**

```bash
# Whenever memory is saved, invalidate cache
memory_save_failure() {
    # ... existing save logic ...

    # NEW: Invalidate cache on write
    memory_cache_invalidate_for_type "failures" "$memory_dir" 2>/dev/null || true
}

# Similar for memory_save_decision, memory_save_pattern, etc.
```

---

### Task 4: Modify sw-memory.sh — Index Integration

**In search loop, use index to pre-filter:**

```bash
# Instead of:
#   jq -c '.failures[]? // empty' "$memory_dir/failures.json" | while read entry...

# Do:
local index
index=$(memory_index_get "$memory_dir")

local matching_indices
matching_indices=$(memory_index_lookup "$index" "failures" "$keywords")

# Now only process matching entries:
jq -c ".failures[${matching_indices}]? // empty" "$memory_dir/failures.json" | while read entry...
```

This reduces full-file scans to only relevant entries (typically 10-20% of total).

---

## Files to Create/Modify

### Files to Create

- [ ] `scripts/lib/memory-index.sh` (new, ~250 lines)
- [ ] `scripts/lib/memory-cache.sh` (new, ~300 lines)
- [ ] `scripts/lib/memory-index-test.sh` (new, ~200 lines)
- [ ] `scripts/lib/memory-cache-test.sh` (new, ~250 lines)

### Files to Modify

- [ ] `scripts/sw-memory.sh` (modify, +~80 lines for cache/index integration)
- [ ] `scripts/sw-memory-test.sh` (modify, +~50 lines for new test cases)
- [ ] `scripts/sw-db.sh` (minimal: add cache table schema, ~15 lines)
- [ ] `.claude/CLAUDE.md` (update AUTO:core-scripts section)

---

## Testing Approach

### Unit Tests

**memory-index-test.sh:**

- Test index building from empty memory dir
- Test lazy rebuild on file mtime changes
- Test keyword lookups
- Test checksum validation
- Test edge cases (empty files, corrupted JSON)

**memory-cache-test.sh:**

- Test cache hit/miss
- Test TTL expiration (mock time)
- Test LRU eviction
- Test concurrent writes
- Test query hashing

**sw-memory-test.sh additions:**

- Test cached query returns correct results
- Verify cache hit rate ≥70% over 10 identical queries
- Verify latency reduction ≥50% for cached vs uncached
- Test cache invalidation on memory writes
- Test backward compatibility (existing memory format untouched)

### Integration Tests

**Performance benchmarks:**

```bash
# Measure before/after optimization
time memory_ranked_search "error handling" ~/.shipwright/memory 100 runs
time memory_ranked_search "test patterns" ~/.shipwright/memory 100 runs
```

Expected:

- Uncached: 150-300ms
- Cached: 30-50ms (5-6x faster)

### Smoke Tests

- Run existing `sw-memory-test.sh` suite (must all pass)
- Run entire test suite (`npm test`) to catch any regressions
- Test daemon startup with memory system active

---

## Definition of Done

All of the following must be true:

- [ ] **Correctness**
  - [ ] All existing memory tests pass (100% backward compatibility)
  - [ ] New tests for index/cache pass with >95% coverage
  - [ ] Memory data files unchanged on disk (format compatibility verified)

- [ ] **Performance**
  - [ ] Query latency reduced by ≥50% for typical searches (verified via benchmarks)
  - [ ] Cache hit ratio ≥70% for daemon-typical workloads (verified via unit tests)
  - [ ] Index rebuild latency <50ms (measured, doesn't block queries)
  - [ ] Cache size bounded (LRU eviction verified, no unbounded growth)

- [ ] **Safety & Reliability**
  - [ ] Index corruption detected and self-healed (unit tested)
  - [ ] Cache invalidation on memory writes (unit tested)
  - [ ] Concurrent access safe (multiple readers, write-through on update)
  - [ ] Handles missing/corrupted memory files gracefully (fallback to full scan)

- [ ] **Code Quality**
  - [ ] New functions documented with inline comments
  - [ ] Follows Shipwright shell conventions (set -euo pipefail, VERSION, etc.)
  - [ ] No new dependencies introduced
  - [ ] CLAUDE.md updated with AUTO:core-scripts changes

- [ ] **Integration**
  - [ ] Existing memory*save*\* functions integrated with cache invalidation
  - [ ] memory_ranked_search works transparently with index/cache
  - [ ] Daemon performance improved (measured if possible)

---

## Failure Mode Analysis

### Failure Mode 1: Index Corruption / Staleness (CRITICAL)

**What can happen:**

- Index built from stale memory files (mtime check races)
- Index points to non-existent entries (file truncated, rebuilt)
- Query returns incorrect results due to stale index

**Likelihood:** Medium (concurrent file writes possible during daemon operation)

**Impact:** Severe (wrong memory injected into agents, incorrect decisions)

**Mitigation:**

1. Add content hash checksums to index (detect corruption)
2. Verify indexed entries actually exist before returning (index-to-file validation)
3. Lazy rebuild with atomic operations (write to temp, mv to final)
4. Add `memory_index_validate()` to detect drift
5. If validation fails, rebuild index and log event

**Code:**

```bash
# In memory_index_build:
# For each indexed entry, verify it still exists in source file
# Compute checksum of entry content, store in index
# On retrieval, recompute checksum and compare

# Fallback: if any validation fails, rebuild index atomically
```

---

### Failure Mode 2: Cache-Reality Drift (HIGH)

**What can happen:**

- Memory file updated (e.g., new failure pattern added)
- Cache not invalidated (write-through missed, or concurrent write outside memory*save*\*)
- Agent receives old cached results for updated query

**Likelihood:** Low (write-through in memory*save*\* functions should cover all paths)

**Impact:** High (agents see stale failure patterns, may miss new fixes)

**Mitigation:**

1. Version memory files with a timestamp (include in cache key)
2. Check memory file mtime on cache hit (if newer, invalidate)
3. Log all cache misses due to staleness for monitoring
4. Add option to disable cache temporarily (emergency mode)

**Code:**

```bash
# In memory_cache_get:
# Before returning cached result:
# Check if any memory file mtime > cache created_at
# If yes: treat as cache miss, rebuild, return fresh result
```

---

### Failure Mode 3: Cache Unbounded Growth / Memory Exhaustion (MEDIUM)

**What can happen:**

- Cache accumulates entries without eviction
- SQLite database grows to gigabytes
- Daemon slows down (disk I/O, memory pressure)
- Eventually runs out of disk space

**Likelihood:** Low if TTL/LRU working, Medium if they fail

**Impact:** Medium (daemon degradation, eventually failure)

**Mitigation:**

1. Hard size limit: delete table and rebuild if >500MB
2. TTL enforcement: delete expired entries on every prune
3. LRU eviction: keep only top-N by hit_count
4. Monitor via `memory_cache_stats()` in daemon patrol

**Code:**

```bash
# In memory_cache_prune (called periodically):
# 1. DELETE where created_at + ttl < now()
# 2. Count remaining rows
# 3. If > 10000 rows, DELETE lowest hit_count entries until < 5000
# 4. Check file size; if > 500MB, warn and consider dropping table

# Add to daemon patrol: emit warning if cache hit_rate < 30% (sign of excessive misses)
```

---

### Failure Mode 4: Concurrent Write Race Conditions (MEDIUM)

**What can happen:**

- Two agents simultaneously call memory_save_failure()
- One writes memory file, attempts to invalidate cache
- Other agent's cache check and write interleave
- Cache inconsistency or SQLite lock contention

**Likelihood:** Low (daemon runs sequentially), Medium (fleet mode with parallel agents)

**Impact:** Medium (temporary cache inconsistency, eventually resolves via TTL)

**Mitigation:**

1. Use SQLite transactions for cache operations
2. Atomic invalidation: use `TRANSACTION` block to ensure atomicity
3. Retry logic with backoff for write-through
4. Use file locking for memory file writes (if not already)

**Code:**

```bash
# In memory_cache_set and memory_cache_invalidate:
# Wrap in sqlite transaction:
# BEGIN TRANSACTION
# ... update/delete ...
# COMMIT

# In memory_save_* functions:
# Use write-through with retry:
memory_cache_invalidate_for_type "failures" "$memory_dir" || {
  warn "cache invalidation failed, will expire via TTL"
}
```

---

### Failure Mode 5: Daemon Restart / Cache Loss Across Sessions (LOW)

**What can happen:**

- Daemon restarts
- SQLite cache persists, but in-memory index is cleared
- First query after restart: cache hits SQLite, but index build takes time
- On subsequent restarts, cache is "warm" but index rebuilds

**Likelihood:** Low (expected behavior, acceptable trade-off)

**Impact:** Low (temporary latency spike on restart, resolves after first rebuild)

**Mitigation:**

1. Persist index in SQLite too (denormalized for fast loading)
2. Load index from DB on startup (fast, no file I/O)
3. Accept temporary latency spike as acceptable (first queries are slower)

**Code:**

```bash
# Optional: add memory_index table to SQLite
# On daemon startup: load index from DB (much faster than rebuilding from files)
# This is a future optimization; acceptable to skip for MVP

# For now: accept that first few queries after restart are uncached
```

---

## Most Critical Failure Mode: Index Corruption

**Chosen for detailed mitigation:**

I'm prioritizing **Failure Mode 1 (Index Corruption)** because:

1. **Highest impact:** Corrupted index → wrong memory → wrong agent decisions
2. **Medium likelihood:** Concurrent writes during daemon operation
3. **Hard to detect:** Subtle corruption might go unnoticed

**Mitigation in code:**

```bash
# In lib/memory-index.sh

# Add function to validate index integrity
memory_index_validate() {
    local index_file="$1" memory_dir="$2"
    [[ -f "$index_file" ]] || return 1

    local index
    index=$(cat "$index_file")

    # For each indexed entry, verify it exists
    local failures_count
    failures_count=$(jq '.failures | length' "$index" 2>/dev/null || echo 0)

    # Spot-check by verifying first entry
    local first_failure_idx
    first_failure_idx=$(jq '.failures | to_entries[0].value[0]' "$index" 2>/dev/null)

    if [[ -n "$first_failure_idx" ]]; then
        jq ".failures[$first_failure_idx]" "$memory_dir/failures.json" >/dev/null 2>&1 || {
            error "Index validation failed: entry not found at index $first_failure_idx"
            return 1
        }
    fi

    return 0
}

# In memory_index_build, after writing index:
if ! memory_index_validate "$index_file" "$memory_dir"; then
    warn "Index validation failed, rebuilding..."
    rm -f "$index_file"
    # Retry build
fi
```

---

## Alternatives Considered Recap

| Aspect                    | Alt 1: LRU Only | Alt 2: SQLite FTS | Alt 3: Hybrid (CHOSEN) |
| ------------------------- | --------------- | ----------------- | ---------------------- |
| Implementation Complexity | Low             | Very High         | Medium                 |
| Performance Gain          | 50-60%          | 70-80%            | 65-75%                 |
| Data Integrity Risk       | Low             | High (migration)  | Low                    |
| Backward Compatibility    | ✓               | ✗ (breaks)        | ✓                      |
| Blast Radius              | Small           | Large             | Moderate               |
| Future Extensibility      | Limited         | Excellent         | Good                   |
| Time to Complete          | 1 day           | 3-5 days          | 2 days                 |

**Choice Rationale:** Alt 3 gives best combination of speed, safety, and time-to-completion. It can be extended with FTS5 later without rework.

---

## Task Checklist

### Phase 1: Foundation

- [ ] **Task 1:** Create `lib/memory-index.sh` (~250 lines)
  - [ ] `memory_index_build()` — build index from memory files
  - [ ] `memory_index_is_fresh()` — check if rebuild needed
  - [ ] `memory_index_get()` — get or build index
  - [ ] `memory_index_lookup()` — find entries by keyword
  - [ ] `memory_index_validate()` — detect corruption
  - [ ] Unit tests for all functions

- [ ] **Task 2:** Create `lib/memory-cache.sh` (~300 lines)
  - [ ] `memory_cache_init()` — create SQLite table
  - [ ] `memory_cache_get()` — check cache (TTL-aware)
  - [ ] `memory_cache_set()` — store result
  - [ ] `memory_cache_invalidate_for_type()` — selective invalidation
  - [ ] `memory_cache_stats()` — get hit rate
  - [ ] `memory_cache_prune()` — LRU/TTL eviction
  - [ ] Unit tests for all functions

### Phase 2: Integration

- [ ] **Task 3:** Modify `sw-memory.sh` — Add cache layer
  - [ ] Add cache check at top of `memory_ranked_search()`
  - [ ] Add cache population before return
  - [ ] Add write-through to `memory_save_failure()`
  - [ ] Add write-through to `memory_save_decision()`
  - [ ] Add write-through to `memory_save_pattern()`
  - [ ] Test backward compatibility

- [ ] **Task 4:** Modify `sw-memory.sh` — Add index layer
  - [ ] Replace full-file scans with indexed lookups
  - [ ] Update search loop to process only matched entries
  - [ ] Measure performance improvement

### Phase 3: Safety

- [ ] **Task 5:** Index validation & self-healing
  - [ ] Add `memory_index_validate()` calls
  - [ ] Auto-rebuild on corruption detection
  - [ ] Log corruption events

- [ ] **Task 6:** Cache management functions
  - [ ] Implement `memory_cache_info()` command
  - [ ] Implement `memory_cache_clear()` command
  - [ ] Implement `memory_cache_prune()` periodic call

- [ ] **Task 7:** Metrics & monitoring
  - [ ] Log cache hit/miss rates to events.jsonl
  - [ ] Track query latency before/after optimization
  - [ ] Add `memory_cache_stats()` to daemon patrol

### Phase 4: Testing

- [ ] **Task 8:** Create `lib/memory-index-test.sh`
  - [ ] Test index building
  - [ ] Test lazy rebuild
  - [ ] Test lookup accuracy
  - [ ] Test corruption detection
  - [ ] Run with `./scripts/lib/memory-index-test.sh`

- [ ] **Task 9:** Create `lib/memory-cache-test.sh`
  - [ ] Test cache get/set
  - [ ] Test TTL expiration
  - [ ] Test LRU eviction
  - [ ] Test concurrent writes
  - [ ] Run with `./scripts/lib/memory-cache-test.sh`

- [ ] **Task 10:** Modify `sw-memory-test.sh`
  - [ ] Add cache hit rate ≥70% assertion
  - [ ] Add latency reduction ≥50% benchmark
  - [ ] Add backward compatibility tests
  - [ ] Run with `./scripts/sw-memory-test.sh`

### Phase 5: Documentation

- [ ] **Task 11:** Inline comments & function docs
  - [ ] Document cache/index architecture in headers
  - [ ] Add performance expectations (before/after)
  - [ ] Update function docstrings

- [ ] **Task 12:** Update CLAUDE.md
  - [ ] Update AUTO:core-scripts table (add lib/memory-index.sh, lib/memory-cache.sh)
  - [ ] Note performance improvements in description

### Final Verification

- [ ] Run full test suite: `npm test` — all pass
- [ ] Backward compatibility verified: existing memory format untouched
- [ ] No new dependencies introduced
- [ ] All tasks marked complete

---

## Success Metrics

**Performance:**

- [ ] Query latency: 150-300ms → 30-100ms (50-70% reduction)
- [ ] Cache hit ratio: ≥70% for typical workloads
- [ ] Index build: <50ms (doesn't block queries)

**Reliability:**

- [ ] Index corruption detected and auto-healed
- [ ] Cache invalidation on every write (zero stale data)
- [ ] Concurrent access safe (tested with multiple readers)

**Code Quality:**

- [ ] 100% backward compatibility (memory files untouched)
- [ ] Test coverage: >95% for new modules
- [ ] All existing tests pass (no regressions)

---

## Timeline Estimate

| Phase         | Tasks    | Estimate       |
| ------------- | -------- | -------------- |
| Foundation    | 1, 2     | 2-3 hours      |
| Integration   | 3, 4     | 1-2 hours      |
| Safety        | 5, 6, 7  | 1-2 hours      |
| Testing       | 8, 9, 10 | 2-3 hours      |
| Documentation | 11, 12   | 30 min         |
| **Total**     | **12**   | **7-11 hours** |

**Expected completion:** 1-2 build loop iterations (depends on test results).

---

## Risk Register

| Risk                                  | Probability | Impact | Mitigation                                          |
| ------------------------------------- | ----------- | ------ | --------------------------------------------------- |
| Index corruption on concurrent writes | Medium      | High   | Atomic operations, validation, auto-rebuild         |
| Cache drift (stale results)           | Low         | High   | Mtime checking, write-through, TTL fallback         |
| Performance regression                | Low         | Medium | Benchmark before/after, fallback to uncached search |
| Cache unbounded growth                | Low         | Medium | LRU eviction, TTL, size limit                       |
| Daemon restart / cache cold start     | Low         | Low    | Acceptable (temporary latency spike)                |
