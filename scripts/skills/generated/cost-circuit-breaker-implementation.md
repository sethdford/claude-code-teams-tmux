## Cost & Resource Circuit Breaker Implementation

### Pattern Overview

A circuit breaker for cost and duration limits must continuously monitor elapsed time and accumulated cost, detect when either limit is exceeded, trigger graceful abort (preserving state), and enable resume from the abort point.

### Monitoring Loop Design

**Check Frequency**: Sample limits every 30–60 seconds during pipeline execution. Balance overhead against detection latency: if stages are 5+ minutes, 60s is safe; if stages are under 2 minutes, use 30s.

**Data Collection**:
- **Elapsed time**: `$(date +%s) - $pipeline_start_time` (absolute, not wall-clock dependent)
- **Accumulated cost**: Sum per-stage costs from `~/.shipwright/costs.json`, not live estimates
- **Limit values**: Loaded at pipeline start, not live-updated (prevents limit-chasing mid-pipeline)

**Atomicity**: Use file-based heartbeat markers (e.g., touching `.claude/pipeline-limit-check.json` with timestamp) to signal limit-exceeded conditions to the main pipeline process, avoiding race conditions from concurrent checks.

### Limit Exceeded Detection

Check both limits at every monitoring interval:

```bash
elapsed_seconds=$(($(date +%s) - pipeline_start_time))
accumulated_cost=$(jq -r '.total // 0' ~/.shipwright/costs.json)

if [[ $elapsed_seconds -gt $global_timeout_seconds ]]; then
  reason="Timeout: $elapsed_seconds seconds exceeds limit of $global_timeout_seconds"
  trigger_abort "$reason"
fi

if (( $(echo "$accumulated_cost > $max_cost" | bc) )); then
  reason="Cost: \$$accumulated_cost exceeds limit of \$$max_cost"
  trigger_abort "$reason"
fi
```

### Graceful Abort Signal

Do NOT `kill -9` immediately. Follow this sequence:

1. **Write abort signal**: Create `.claude/pipeline-abort.json` with reason, elapsed time, accumulated cost
2. **Wait for clean exit**: Send SIGTERM to pipeline; stage loops must check for `.claude/pipeline-abort.json` between iterations and exit cleanly
3. **Timeout escalation**: If process doesn't exit in 10 seconds, escalate to SIGKILL
4. **Save checkpoint immediately**: Before cleanup, invoke `shipwright checkpoint save` to preserve state for resume

```bash
trigger_abort() {
  local reason="$1"
  
  # Signal abort (pipeline reads abort.json and exits cleanly)
  cat > .claude/pipeline-abort.json <<EOF
{"reason":"$reason","elapsed_seconds":$elapsed_seconds,"accumulated_cost":$accumulated_cost}
EOF
  
  # Wait for graceful shutdown
  wait $pipeline_pid || true
  
  # Save checkpoint BEFORE cleanup
  shipwright checkpoint save "Aborted: $reason"
  
  exit 1
}
```

Stage loops must detect and respect abort:

```bash
while true; do
  # Check for abort signal
  if [[ -f .claude/pipeline-abort.json ]]; then
    jq -r '.reason' .claude/pipeline-abort.json
    exit 1
  fi
  
  # Run stage work...
done
```

### Resume After Abort

When user invokes `shipwright pipeline resume`:
1. Load limits from config (may be updated since original abort)
2. Load state from checkpoint
3. Recalculate remaining budget: `$remaining_cost = $max_cost - $cost_at_checkpoint`
4. Recalculate remaining time: `$remaining_seconds = $global_timeout - $elapsed_at_checkpoint`
5. Continue from last completed stage with adjusted limits

Notify operator:
```
Pipeline aborted: Cost limit ($50) exceeded.
Accumulated cost: $52.47
Elapsed time: 2h 15m
Checkpoint saved. Resume with: shipwright pipeline resume
```

### Testing Checkpoints

**Timeout Trigger Test**:
- Start pipeline with `--timeout 30s` (very short for testing)
- Verify abort fires between 30–35 seconds
- Verify `pipeline-abort.json` contains timeout reason
- Verify checkpoint saved and contains stage state
- Verify `shipwright pipeline resume` restarts from same stage

**Cost Limit Test**:
- Mock cost system: inject staged cost updates via `~/.shipwright/costs.json`
- Start pipeline with `--max-cost 40`; update costs to exceed at 50-second mark
- Verify abort fires within 60 seconds of cost exceeding limit
- Verify cost reason in abort.json
- Verify cost in abort.json matches cost.json at abort time

**Checkpoint Durability**:
- Abort during build stage (not at start or end)
- Verify `.claude/pipeline-artifacts/checkpoints/` contains complete stage state
- Resume and verify it restores to exact same point (no re-run of completed stages)

### Edge Cases & Mitigations

**Cost update lag** (cost system delayed 5+ minutes): May exceed limit before detection triggers. Mitigation: Run limit checks 2× per average stage duration; use conservative cost estimates during lag windows.

**Clock skew** (system clock jumps backward): Elapsed time goes negative. Mitigation: Use monotonic clock source (nanoseconds since boot, `/proc/uptime`) instead of wall-clock time.

**Concurrent cost updates**: Multiple stages updating cost file. Mitigation: Enforce atomic writes (temp file + `mv`, never direct echo).

**Abort during checkpoint save**: SIGTERM arrives while checkpoint writing. Mitigation: Checkpoint save is atomic (temp + mv); abort handler waits for in-flight checkpoints before SIGKILL escalation.

**High-frequency limit checks**: Excessive file I/O. Mitigation: Batch checks every 60 seconds; use a background monitoring process rather than checking on every iteration.
