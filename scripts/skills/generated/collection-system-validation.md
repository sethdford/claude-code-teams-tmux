## Collection System Validation & Auto-Repair

### Core Responsibility
Design and implement validators that check heterogeneous data collection systems (events.jsonl, pipeline state, DORA metrics, cost tracking, memory patterns) for health, detect gaps systematically, and safely auto-repair broken collectors.

### Multi-System Validation Architecture

**System-Specific Validators**
- Events system: Check events.jsonl writes, verify timestamps are recent, detect missing event types (pipeline_start, pipeline_complete, stage_start)
- Pipeline state: Verify .claude/pipeline-state.md writes work, timestamps are fresh
- Cost tracking: Validate ~/.shipwright/costs.json updates, compare against expected frequency
- DORA metrics: Check metrics.json is populated, has recent data points
- Memory system: Validate memory files created, readable, contain valid patterns

**Gap Detection Patterns**
- Missing events for active pipelines (spawn time + expected stages = missing events)
- Stale timestamps (last write > threshold, e.g., 24h)
- Unreachable files (ENOENT, EPERM on expected paths)
- Incomplete writes (truncated JSON, missing closing braces)
- Permission issues (ls -l reveals 000 or other broken states)

**Health Scoring**
- Per-system: 0-100 based on recency, write success rate, completeness
- Overall: Weighted average (events 30%, state 25%, cost 15%, DORA 20%, memory 10%)
- Thresholds: Critical (<30), Warning (30-70), Healthy (>70)

### Auto-Repair Strategies (Safety First)

**File System Repairs**
- Fix permissions: `chmod 755 ~/.shipwright/` (idempotent, safe)
- Create missing dirs: `mkdir -p` on standard paths (safe if idempotent)
- Cleanup truncated files: Back up to `.bak`, recreate empty or last-known-good version
- Rotate stale logs: Move logs >30d to archive (preserve data)

**Collector Restarts**
- Daemon restart: Signal SIGHUP, not SIGKILL (graceful)
- Loop restart: Only if process is hung (check for zombie)
- Checkpoint restore: Use last valid state from .claude/checkpoints/ before restart

**Data Restoration**
- Never delete data unilaterally—always preserve backups
- Restore from last checkpoint if available
- If repair requires data loss, alert and wait for manual approval

### Health Reporting Format

```json
{
  "timestamp": "2026-03-10T14:23:00Z",
  "overall_health": 85,
  "systems": {
    "events": {"health": 95, "last_write": "2026-03-10T14:22:00Z", "status": "healthy"},
    "pipeline_state": {"health": 80, "last_write": "2026-03-10T14:21:00Z", "status": "warning", "gaps": ["build stage missing"]},
    "cost_tracking": {"health": 100, "last_write": "2026-03-10T14:20:00Z", "status": "healthy"},
    "dora_metrics": {"health": 60, "last_write": "2026-03-10T12:00:00Z", "status": "warning", "stale_hours": 2},
    "memory": {"health": 90, "status": "healthy"}
  },
  "repairs_attempted": [{"system": "dora", "action": "chmod 755", "success": true}],
  "alerts": ["DORA metrics not updated in 2 hours"]
}
```

### Patrol Integration

**Daily Validation Run**
- Schedule: 02:00 UTC (off-peak, before metrics review)
- Runs: `shipwright metrics validate --repair` (auto-repair enabled in daemon)
- Output: JSON + summary logged to events.jsonl with type `metrics_validation`

**Alert Thresholds**
- Overall health < 70: Alert to patrol log, escalate for manual review
- Missing events > 5 consecutive runs: Critical alert
- Permission failures: Attempt repair, alert if repair fails

**Repair Decision Logic**
- Low-risk repairs (permissions, mkdir): Auto-execute
- Medium-risk (truncated file cleanup): Log and alert, wait 10 min for manual override, then auto-execute
- High-risk (collector restart): Alert and wait for approval, or skip if patrol is in critical path

### Testing Strategy

**Unit Tests per Validator**
- events.jsonl: Simulate ENOENT, EPERM, truncated JSON, missing event types
- State file: Simulate stale timestamp, missing fields
- Cost tracker: Simulate missing file, zero events
- DORA: Simulate outdated metrics.json, malformed JSON
- Memory: Simulate unreadable patterns, corrupted files

**Integration Test (Proof of Repair)**
1. Create healthy baseline (all systems populated)
2. Inject failures (chmod 000, truncate file, stop daemon)
3. Run validator with --repair
4. Verify: All systems restored to healthy state, backups created, alerts fired
5. Run again: Zero new repairs needed (idempotency proof)

**Negative Tests**
- High-risk repairs skipped correctly when approval not given
- Repair doesn't cause data loss (backups preserved)
- Validator doesn't create false positives on legitimate stale data (e.g., idle repos)
