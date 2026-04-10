# Implementation Plan: System-Wide Health Regression Detector with Automatic Intelligence Rollback

## Brainstorming: Socratic Design Refinement

### Requirements Clarity

**Minimum viable change**: A new script `scripts/sw-health-regression.sh` that:
1. Reads `pipeline.completed` events from `events.jsonl` to compute rolling success rates
2. Stores baselines in `~/.shipwright/health-baseline.json`
3. Detects when success rate drops below 85% of the 7-day baseline for 3+ consecutive runs
4. Backs up and reverts auto-generated intelligence state files
5. Logs rollback actions to `~/.shipwright/rollback-log.jsonl`
6. Emits events to the event bus

**Implicit requirements**:
- Must be callable from the daemon after each pipeline completes (integration point)
- Must distinguish auto-generated vs user-edited config (only revert auto state)
- Must be idempotent — running the check twice shouldn't double-rollback

### Design Alternatives

**Approach A: Standalone script with daemon hook** (chosen)
- New `scripts/sw-health-regression.sh` with subcommands: `check`, `status`, `rollback`, `reset`
- Daemon calls `health-regression check` after each pipeline completion
- Reads events.jsonl directly via jq for success rate calculation
- Trade-offs: Simple, follows existing patterns exactly, no new dependencies
- Blast radius: 1 new script + 1 new test + minor daemon integration

**Approach B: Extend sw-regression.sh**
- Add health regression detection to existing regression script
- Trade-offs: Less file sprawl but conflates two different regression types (code metrics vs pipeline health)
- Rejected: The existing regression.sh tracks test count/pass rate/script metrics — fundamentally different from pipeline success rate tracking

**Approach C: Library function in sw-self-optimize.sh**
- Since self-optimize already tracks outcomes, add regression detection there
- Trade-offs: Reuses outcome data, but self-optimize is already 1690 lines and has a different concern (tuning, not reverting)
- Rejected: Violates single responsibility; rollback should be independent of the tuning system it reverts

### Risk Assessment

1. **False positive rollbacks**: If the 15% threshold is too sensitive for small sample sizes (e.g., 2 of 3 runs fail -> 33% rate vs 80% baseline), we could trigger unnecessary rollbacks. **Mitigation**: Require minimum 5 runs in the 24h window before comparing against baseline.
2. **Partial rollback corruption**: If rollback fails mid-way (e.g., reverted cache but crash before reverting model routing), system is in inconsistent state. **Mitigation**: Backup all files first, then revert atomically; if any revert fails, restore from backup.
3. **Stale baseline**: If no pipeline runs happen for days, the 7-day baseline could be based on very old data. **Mitigation**: Require at least 3 runs in the 7-day window for a valid baseline; otherwise skip health check.

### Dependency Analysis

- **Reads**: `~/.shipwright/events.jsonl` (pipeline.completed events)
- **Reverts**: `.claude/intelligence-cache.json`, `~/.shipwright/optimization/model-routing.json`, `~/.shipwright/optimization/template-weights.json`, `~/.shipwright/adaptive-models.json`
- **Does NOT touch**: `.claude/daemon-config.json` (user-editable)
- **Called by**: `scripts/sw-daemon.sh` (after pipeline completion)
- **No circular dependencies**: Health regression is a leaf consumer of events

### Simplicity Check

Two files is the minimum: one script + one test. The daemon integration is ~5 lines. This is already minimal.

---

## Architecture Decision Record

### Component Decomposition

1. **Health Baseline Manager** — Reads events, computes rolling 7-day and 24-hour success rates, persists to `health-baseline.json`
2. **Regression Detector** — Compares current rate against baseline, tracks consecutive failure count
3. **Intelligence Rollback Engine** — Backs up and reverts auto-generated state files
4. **Event/Log Emitter** — Emits events to event bus and writes to rollback log

### Interface Contracts

```bash
# Public API (subcommands)
health_regression_check()    # exit 0 (healthy) | exit 1 (regression detected + rolled back)
health_regression_status()   # prints current health metrics as JSON
health_regression_rollback() # manual trigger of rollback
health_regression_reset()    # clears consecutive failure counter
```

### Design Decision: Why 85% of baseline (not absolute threshold)

**Context**: Different projects have different natural success rates. A project at 90% baseline dropping to 76% is concerning; a project at 60% baseline dropping to 50% is also concerning.
**Decision**: Use relative threshold (0.85 x baseline) not absolute.
**Alternatives**: Fixed 70% threshold — rejected because it doesn't adapt to project norms.
**Consequences**: Need valid baseline data; first runs have no baseline to compare against.

### Design Decision: Files to rollback

**Context**: The issue says "reverts intelligence cache, adaptive overrides, model routing changes from last 24h" but "does NOT rollback user-edited daemon-config.json".
**Decision**: Rollback these specific auto-generated files:
- `.claude/intelligence-cache.json` -> delete entries with timestamps in last 24h (or restore backup)
- `~/.shipwright/optimization/model-routing.json` -> restore pre-regression backup
- `~/.shipwright/optimization/template-weights.json` -> restore pre-regression backup
- `~/.shipwright/adaptive-models.json` -> restore pre-regression backup

**NOT rolled back**: `.claude/daemon-config.json`, `~/.shipwright/optimization/outcomes.jsonl` (append-only log, valuable for analysis)

---

## Files to Modify

### New Files
1. `scripts/sw-health-regression.sh` — Main health regression detector (~400 lines)
2. `scripts/sw-health-regression-test.sh` — Comprehensive test suite (~350 lines)

### Modified Files
3. `scripts/sw` — Add `health-regression` subcommand routing (~2 lines)
4. `scripts/sw-daemon.sh` — Call health regression check after pipeline completion (~5 lines)
5. `package.json` — Register test suite in vitest config

---

## Implementation Steps

### Step 1: Create `scripts/sw-health-regression.sh`

Standard script structure following existing conventions:
- Boilerplate: `set -euo pipefail`, `VERSION="3.3.0"`, source compat.sh + helpers.sh
- Constants: `HEALTH_BASELINE_FILE`, `ROLLBACK_LOG_FILE`, `BACKUP_DIR`

### Step 2: Implement baseline computation

```bash
compute_success_rate(window_seconds)
```
- Query `events.jsonl` for `pipeline.completed` events within window
- Count total vs `result == "success"`
- Return rate as percentage (0-100)
- Minimum sample size: 3 runs for 7-day, 3 runs for 24-hour

### Step 3: Implement baseline persistence

```bash
update_health_baseline()
```
- Compute 7-day and 24-hour rates
- Write to `~/.shipwright/health-baseline.json`:
```json
{
  "seven_day_rate": 85.0,
  "seven_day_count": 20,
  "twenty_four_hour_rate": 75.0,
  "twenty_four_hour_count": 5,
  "updated_at": "2026-04-10T12:44:15Z",
  "updated_epoch": 1775316255,
  "consecutive_failures": 2
}
```

### Step 4: Implement regression detection

```bash
detect_regression()
```
- Load baseline from `health-baseline.json`
- If `twenty_four_hour_rate < 0.85 * seven_day_rate`, increment `consecutive_failures`
- If `consecutive_failures >= 3`, trigger rollback
- If rate recovers, reset `consecutive_failures` to 0

### Step 5: Implement intelligence rollback

```bash
rollback_intelligence_state()
```
- Create backup dir: `~/.shipwright/health-rollback-backups/<timestamp>/`
- For each auto-generated file:
  - Copy current version to backup dir
  - Check file mtime — only revert if modified in last 24h
  - For intelligence-cache.json: truncate entries newer than 24h (via jq)
  - For model-routing.json, template-weights.json, adaptive-models.json: restore from previous backup or reset to `{}`
- Log each action to `~/.shipwright/rollback-log.jsonl`

### Step 6: Implement event emission

After rollback:
```bash
emit_event "health.regression_detected" \
    "seven_day_rate=$seven_day_rate" \
    "twenty_four_hour_rate=$twenty_four_hour_rate" \
    "consecutive_failures=$consecutive_failures" \
    "rollback=true" \
    "files_reverted=$reverted_count"
```

### Step 7: Implement rollback log

Append JSONL to `~/.shipwright/rollback-log.jsonl`:
```json
{
  "ts": "2026-04-10T12:44:15Z",
  "reason": "success_rate_regression",
  "seven_day_rate": 85.0,
  "twenty_four_hour_rate": 55.0,
  "threshold": 72.25,
  "consecutive_failures": 3,
  "reverted_files": [
    "intelligence-cache.json",
    "model-routing.json"
  ]
}
```

### Step 8: Implement CLI subcommands

- `check` — Run detection + auto-rollback if needed
- `status` — Show current health baseline and consecutive failure count
- `rollback` — Manually trigger rollback
- `reset` — Clear consecutive failure counter
- `help` — Usage information

### Step 9: Add CLI routing in `scripts/sw`

Add `health-regression)` case to the command router dispatching to `sw-health-regression.sh`.

### Step 10: Integrate with daemon

In `scripts/sw-daemon.sh`, after pipeline completion (where `optimize_analyze_outcome` is called), add:
```bash
# Health regression check after each pipeline completion
if [[ -f "$SCRIPT_DIR/sw-health-regression.sh" ]]; then
    "$SCRIPT_DIR/sw-health-regression.sh" check 2>/dev/null || true
fi
```

### Step 11: Create test suite `scripts/sw-health-regression-test.sh`

Tests:
1. **Baseline computation**: Seed events.jsonl with known pipeline.completed events, verify 7-day and 24-hour rates
2. **No regression**: 80% baseline, 78% current -> no rollback (above 85% threshold)
3. **Regression detected but <3 consecutive**: Only 2 consecutive failures -> no rollback yet
4. **Regression triggers rollback**: 80% baseline -> 55% current for 3 runs -> rollback triggered
5. **Files actually reverted**: Create mock auto-generated files, trigger rollback, verify they are reverted/truncated
6. **User config not touched**: Verify daemon-config.json is not modified
7. **Rollback log written**: Verify JSONL line appended with correct fields
8. **Event emitted**: Check events.jsonl for health.regression_detected event
9. **Recovery resets counter**: After rollback, simulate passing runs, verify consecutive_failures resets to 0
10. **Minimum sample size**: With only 1 run, health check should skip (not enough data)
11. **Status command**: Verify JSON output of current baseline

### Step 12: Register test in package.json

Add `"sw-health-regression-test"` to the test script list.

---

## Task Checklist

- [ ] Task 1: Create `scripts/sw-health-regression.sh` with boilerplate, constants, helper fallbacks
- [ ] Task 2: Implement `compute_success_rate()` and `update_health_baseline()` functions
- [ ] Task 3: Implement `detect_regression()` with consecutive failure tracking
- [ ] Task 4: Implement `rollback_intelligence_state()` with atomic backup-then-revert
- [ ] Task 5: Implement rollback log writer and event emission
- [ ] Task 6: Implement CLI subcommands (check, status, rollback, reset, help)
- [ ] Task 7: Add `health-regression` routing to `scripts/sw` CLI router
- [ ] Task 8: Add daemon integration in `scripts/sw-daemon.sh` post-pipeline hook
- [ ] Task 9: Create `scripts/sw-health-regression-test.sh` with all test cases
- [ ] Task 10: Register test suite in `package.json`
- [ ] Task 11: Run full test suite to verify no regressions

**Dependencies**: Tasks 1-6 are sequential (build up the script). Task 7 depends on Task 6. Task 8 depends on Task 6. Task 9 depends on Task 6. Tasks 7, 8, 9 can run in parallel after Task 6.

---

## Testing Approach

### Test Pyramid Breakdown
- **Unit tests** (11 tests in `sw-health-regression-test.sh`): All core functions tested with mock events.jsonl data
- **Integration test** (1 test): Simulates drop from 80% to 55% over 3 consecutive runs, verifies full rollback flow including file revert and event emission
- **No E2E test needed**: This is an internal subsystem; the daemon integration is tested via existing daemon tests

### Coverage Targets
- 100% of public subcommands (check, status, rollback, reset)
- 100% of regression detection logic (threshold math, consecutive tracking)
- 100% of rollback logic (file backup, revert, log)
- Edge cases: empty events file, insufficient samples, already-rolled-back state

### Critical Paths to Test
- **Happy path**: Normal operation, no regression -> exit 0
- **Error case 1**: Regression detected, rollback succeeds -> exit 1, files reverted
- **Error case 2**: No baseline data (first run) -> exit 0, baseline created
- **Edge case 1**: Events file missing -> exit 0, skip check gracefully
- **Edge case 2**: Rollback target files don't exist -> skip those files, log warning

---

## Definition of Done

- [ ] `scripts/sw-health-regression.sh` exists with all subcommands working
- [ ] `shipwright health-regression check` computes success rates from events.jsonl
- [ ] Rolling 7-day and 24-hour rates stored in `~/.shipwright/health-baseline.json`
- [ ] Regression detected when 24h rate < 0.85 x 7-day rate for >=3 consecutive runs
- [ ] Auto-rollback reverts: intelligence-cache.json, model-routing.json, template-weights.json, adaptive-models.json
- [ ] Does NOT touch daemon-config.json
- [ ] Rollback logged to `~/.shipwright/rollback-log.jsonl` with reason and file list
- [ ] Event `health.regression_detected` emitted to event bus
- [ ] Daemon calls health check after each pipeline completion
- [ ] Integration test proves 80%->55% drop triggers rollback and file revert
- [ ] All existing tests continue to pass
- [ ] Script follows bash 3.2 compatibility, set -euo pipefail, VERSION sync

---

## Failure Mode Analysis

### 1. Race condition: concurrent daemon pipelines complete simultaneously

**What breaks**: Two pipelines finish at the same time, both call `health-regression check`, both detect regression, both try to rollback the same files.
**Mitigation**: Use `flock` on `~/.shipwright/health-regression.lock` during the check+rollback operation, matching the existing event bus locking pattern. Second caller waits for first to complete.

### 2. Rollback of intelligence cache corrupts JSON

**What breaks**: The intelligence cache is a complex nested JSON file. Filtering entries by timestamp with jq could produce invalid JSON if the file is malformed or being written to concurrently.
**Mitigation**: Read the entire file into a variable first, process with jq, write to a temp file, validate with `jq . < tmpfile >/dev/null 2>&1`, then `mv` atomically. If validation fails, fall back to restoring from backup.

### 3. Runaway rollback loop: rollback doesn't fix the problem, next pipeline still fails

**What breaks**: After rollback, the next pipeline fails for an unrelated reason (e.g., flaky test). Consecutive counter keeps incrementing, triggering repeated rollbacks (though there's nothing left to revert).
**Mitigation**: After a rollback, set a cooldown period (1 hour). During cooldown, skip health regression checks. Store `last_rollback_epoch` in health-baseline.json and check against it.

### Addressing the most critical failure mode (Race condition)

The `flock` approach is implemented in the rollback function:
```bash
(
    flock -n 200 || { warn "Health regression check already running"; exit 0; }
    # ... detection and rollback logic ...
) 200>"${HOME}/.shipwright/health-regression.lock"
```
This ensures only one health check runs at a time, preventing duplicate rollbacks.

---

## Monitoring Checklist

### P0 — After deployment
- **Rollback frequency**: Monitor `rollback-log.jsonl` — more than 1 rollback per day indicates threshold is too sensitive
- **False positive rate**: Track rollbacks that didn't improve subsequent pipeline success rates
- **Health check duration**: Should complete in <2 seconds (jq query on events.jsonl)

### P1 — Short-term (first week)
- **Baseline accuracy**: Verify 7-day rates match manual calculation from events
- **Consecutive counter behavior**: Confirm resets properly after recovery
- **Daemon integration**: Verify check runs after every pipeline completion

### Anomaly Detection Triggers
- Rollback triggered when 24h sample size < 5 (potential false positive)
- More than 3 rollbacks in 24 hours (system may be in a failure spiral)
- Health check takes > 5 seconds (events.jsonl may be too large)

### Auto-Rollback Decision Criteria
This feature IS the auto-rollback system. Its own rollback story: if the health regression detector itself causes problems, it can be disabled by setting `SW_HEALTH_REGRESSION_DISABLED=true` or removing the daemon integration line.

---

## Systematic Debugging Notes

This is the first implementation attempt — no previous failures to analyze. The plan is based on thorough codebase analysis of:
- `sw-regression.sh` (existing per-metric regression, pattern to follow)
- `sw-self-optimize.sh` (files to rollback, storage paths)
- `sw-daemon.sh` (integration point after pipeline completion)
- `sw-adaptive.sh` (reads pipeline.completed events, model routing state)
- Event bus patterns (emit_event, events.jsonl format)
- Test harness patterns (mock binaries, PATH override, PASS/FAIL counters)

**Root Cause Hypothesis** (for potential failures during build):
1. Most likely: jq query for filtering events by timestamp may need careful epoch arithmetic (use `date +%s` not date string comparison)
2. Possible: Intelligence cache JSON structure is more complex than expected — need to handle nested entries carefully
3. Unlikely: Bash 3.2 compatibility issue — all operations use standard tools (jq, date, mv, cp)

**Verification Plan**: Run `scripts/sw-health-regression-test.sh` and then full `npm test` suite.
