# Pipeline Tasks — Memory System Performance Optimization with Query Index & Cache Layer

## Implementation Checklist
- [ ] Task 1: Write `sw-memory-bench.sh`, capture baseline p50/p95/p99 → `memory-bench-baseline.json`
- [x] Task 2: Create `lib/memory-query.sh`; move `memory_ranked_search` + keyword helpers out of sw-memory.sh
- [x] Task 3: Add `source lib/memory-query.sh` to sw-memory.sh + standalone fallbacks; confirm sw-memory.sh shrinks
- [ ] Task 4: Integrate `memory_index_lookup` candidate-narrowing into the scan (gated by `SW_MEMORY_INDEX`)
- [ ] Task 5: Hook `memory_index_build` into the 4 write functions (`|| true`, function-guarded)
- [ ] Task 6: Add LRU-50 row cap + `last_used` eviction to `memory_cache_put`/`get`
- [x] Task 7: Add `memory.query_time` timing instrumentation (GNU/BSD-safe via compat)
- [ ] Task 8: Run after-benchmark; assert cold p95 < 100ms and index-on == index-off byte parity
- [ ] Task 9: Create `sw-lib-memory-query-test.sh` (extraction unit tests)
- [ ] Task 10: Extend `sw-memory-test.sh` (write→index update, scan parity) and `sw-memory-cache-test.sh` (LRU cap)
- [ ] Task 11: Register `sw-lib-memory-query-test.sh` in `package.json` test chain
- [ ] Task 12: Document per-repo-index & SQLite-vs-in-memory deviations in `design.md`
- [ ] Task 13: Run full `npm test` (or affected suites) green; verify `shipwright memory show`/`search` still work end-to-end
- [ ] `lib/memory-query.sh` exists; `memory_ranked_search` no longer defined in `sw-memory.sh`; sw-memory.sh line count reduced
- [ ] L2 index narrows the scan; `memory_index_lookup`/`memory_index_build` are actually called from the runtime path
- [ ] Index updates on every memory write; corrupt index self-heals (tested)
- [ ] Cache bounded to ≤50 LRU rows (tested)
- [ ] After-benchmark shows cold-lookup p95 < 100ms at N=500, recorded in `memory-bench-after.json`
- [ ] Index-on and index-off outputs are byte-identical (parity test green)
- [ ] New test registered in `package.json`; `npm test` passes

## Context
- Pipeline: standard
- Branch: refactor/memory-system-performance-optimization-w-671
- Issue: #671
- Generated: 2026-06-19T19:11:13Z
