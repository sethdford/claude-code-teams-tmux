## Real-Time Metrics Safety for Build Loop Observability

### File I/O Race Condition Prevention
- **Atomic writes only**: Use temp file + `mv` pattern when writing build_loop_status.json. Never update in-place.
- **Reader resilience**: Dashboard server must handle:
  - Missing file (old loops, fresh session)
  - Partial/corrupted JSON (mid-write race)
  - Stale data (loop paused or failed)
- **Write barriers**: Ensure build loop flushes JSON to disk (fsync equivalent in shell) before marking iteration complete.

### Polling & Refresh Strategy
- **10-second interval** is reasonable for observability but verify: Does faster polling (5s) give meaningful value? Does slower (15s) cause user frustration during fast iterations?
- **Browser caching**: Set `Cache-Control: no-cache, no-store` headers on the metrics endpoint to prevent stale reads.
- **Backoff logic**: If metrics file is missing for >30 seconds, show "Loop inactive" rather than error state.
- **Load limits**: If 100+ dashboards poll the same metrics file every 10 seconds, consider in-memory cache in dashboard server with TTL.

### Trend Calculation
- Trends require baseline: Use iteration N-1 as fallback, or N-5 if available. First iteration always shows ⟷ (stable).
- **Degradation detection**: If test_status changed from PASS to FAIL, show ⬇. If files_changed jumped 2x, show ⬆.
- **Context warning**: If context_usage_percent > 80%, highlight in red. If trending upward, warn user before exhaustion.

### Error Handling
- Dashboard server crash = no visibility. Wrap JSON parsing in try/catch and return cached last-good metrics on parse failure.
- CLI `shipwright loop status` should work even if metrics file is 30 seconds stale (show timestamp: "as of 12:34:56").
- Never block build loop waiting for metrics writes—use non-blocking I/O or fire-and-forget async writes.

### Testing Checklist
- ✓ Write metrics while reading: No corruption detected
- ✓ Missing metrics file: Both dashboard and CLI handle gracefully
- ✓ Dashboard reconnect after 10s gap: Shows correct current state
- ✓ Context percent matches Claude API usage: Verify against cost tracking
- ✓ Trend detection: ⬆/⬇/⟷ match iteration-to-iteration changes
