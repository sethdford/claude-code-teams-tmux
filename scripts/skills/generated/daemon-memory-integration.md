## Daemon-Memory Integration Pattern

When daemon components query external stores (memory, intelligence cache, fleet state), follow these principles to ensure reliability and backward compatibility.

### Graceful Degradation
- Memory queries MUST have a timeout (recommend ≤100ms) and fallback to silent no-op if unavailable
- Check feature flags and mode detection explicitly (e.g., `fleet_mode_enabled()`) before querying fleet-scoped memory
- Log warnings to event log but never error if memory store is missing, unreadable, or malformed
- Ensure standalone mode produces identical behavior whether memory is present or not
- Test explicitly: "feature present" vs "feature absent" paths must be identical for baseline behavior

### Optional Output Fields
- New fields added to daemon output (e.g., `known_pattern_match`) MUST be optional and present only when the feature succeeds
- Consuming code should handle absence gracefully: `pattern_match = output.known_pattern_match // null`
- Document all new daemon output fields in schema files and update test fixtures
- Version output format if introducing breaking changes; use feature detection rather than version checks

### Performance & Latency
- Profile memory queries before merge — add <10ms overhead per call maximum
- For hot paths (like triage loop), cache results with short TTL (30-60s) to avoid O(n²) lookups
- Add instrumentation: log query latencies, cache hit rates, and timeouts to structured event log
- Establish latency baseline in pre-merge testing; regression > 5% blocks merge

### Error Handling & Observability
- Distinguish between transient errors ("unavailable now") and permanent failures ("corrupted") in logging
- Use structured logging format: `level=warn event=memory_query_timeout feature=pattern_match duration_ms=125 fallback=enabled`
- Never let memory integration errors bubble up; wrap all queries in try-catch with sensible defaults
- Add event type to `config/event-schema.json` for this feature (e.g., `daemon_memory_query`)

### Testing Patterns
- Test matrix: (memory present + valid) × (absent) × (malformed) × (timeout simulated)
- Test matrix: (standalone mode) × (fleet mode)
- Verify that disabling the feature leaves scores unchanged (backward compatibility)
- Add fixtures for real-world memory states: empty store, 1000 patterns, corrupted entries, stale timestamps
- Measure and assert tail latencies (P95/P99) to catch cascading slowdowns

### Cross-Repo Considerations
- When accessing fleet-scoped memory, use explicit opt-in via config (e.g., `fleet_memory_queries_enabled`)
- Query only repo-agnostic patterns by default; require explicit allowlist for cross-repo pattern matching
- Log which repo's memory was queried for audit trails and debugging
- If memory access fails, fall back cleanly — never block daemon on external state
