# Design: Build Loop Iteration Efficiency Scoring and Early Abort

## Context

The build loop (`scripts/sw-loop.sh`, 3313 lines) runs iterative Claude sessions to accomplish development goals. Currently, the loop has two termination mechanisms: a **circuit breaker** (trips after 3 consecutive iterations with <5 net line insertions) and a **max iteration cap** (with optional auto-extend). Neither mechanism measures whether iterations are _productive_ — a loop can churn through iterations making changes that don't advance the goal (new code that doesn't fix tests, expensive iterations that accomplish nothing).

**Problem**: Loops waste budget on low-value iterations. An iteration that costs $0.15 but produces no test improvement and minimal code changes should count against a productivity threshold, not just a raw line-count threshold.

**Constraints**:

- Bash 3.2 compatible (no associative arrays, no `${var,,}`)
- Atomic file writes (tmp + mv pattern)
- JSON via `jq --arg` (no string interpolation)
- Existing circuit breaker must remain as a fallback — efficiency abort is a _peer_ mechanism, not a replacement
- `TEST_PASSED` is boolean (`"true"`/`"false"`/`""`), not a pass rate — scoring must work with binary test outcomes
- Token cost is already tracked in `LOOP_COST_MILLICENTS` (integer arithmetic, millicents)

## Decision

### Approach: Inline functions in `sw-loop.sh` with JSONL history

Add 4 functions directly into `sw-loop.sh` (after `check_circuit_breaker()` at line ~1053) rather than creating a separate sourced library. This preserves the existing single-file architecture, keeps the sed-extract test pattern working, and avoids introducing a source dependency.

### Scoring Algorithm (40/40/20 weighted composite, 0-100 scale)

**Progress Score (40% weight)** — measures code output per iteration:

```
lines = net insertions + deletions from `git diff --stat HEAD~1` (excludes .json/.md bookkeeping)
score = threshold lookup: 0 lines → 0, 1-4 → 20, 5-19 → 40, 20-49 → 60, 50-99 → 80, 100+ → 100
```

Rationale: Thresholded scoring (not linear) prevents gaming via whitespace changes and gives meaningful tiers. Uses the same `git diff --stat` approach as existing `check_progress()`.

**Productivity Score (40% weight)** — measures test state transitions:

```
fail → pass = 100  (the goal: fixing a broken test)
maintained pass = 80  (keeping green while making changes)
pass → fail = 0  (regression)
still failing = 30  (no improvement but not a regression)
no test configured / first iteration = 50  (neutral)
```

Rationale: Binary test outcome (`TEST_PASSED`) is the only signal available. This discrete scoring avoids the complexity of parsing test pass rates from heterogeneous test output formats. The `fail → pass` transition is the highest-value event in the loop.

**Cost-Effectiveness Score (20% weight)** — measures budget efficiency:

```
if no TEST_CMD or no cost data: score = 100 (neutral, don't penalize)
if test just fixed (fail→pass): score = max(0, 100 - (iteration_cost_millicents / 50000) * 100)
  → $0.50 or less per fix = 0 penalty; $5.00 per fix = fully penalized
if no test fixed: score = max(0, 100 - (iteration_cost_millicents / 20000) * 100)
  → $0.20 or less = 0 penalty; $2.00 = fully penalized
```

Rationale: Non-fix iterations are held to a tighter cost threshold. When no test command is configured, cost scoring is neutral to avoid penalizing non-test-driven loops.

**Composite Score**: `(progress × 0.4) + (productivity × 0.4) + (cost × 0.2)`

All arithmetic uses integer math (`$(( ))`) with scores 0-100. No floating point.

### Abort Logic

- Track `CONSECUTIVE_LOW_EFFICIENCY` counter (threshold: score < 30)
- After **3 consecutive** iterations scoring below 30: set `STATUS="efficiency_abort"` and break
- Only fires after iteration ≥ 3 (allow ramp-up in first 2 iterations)
- Warning emitted when last 3 scores are all below 50 (trend warning, not abort)
- Existing circuit breaker (`check_circuit_breaker()`) remains — checked first, efficiency abort checked second

### Data Flow

```
run_single_agent_loop iteration:
  ... (existing: run_claude_iteration, run_test_gate, check_progress) ...
  ├── compute_iteration_efficiency()          # NEW: calculates score from git/test/cost data
  │   ├── reads: git diff --stat HEAD~1
  │   ├── reads: TEST_PASSED, PREV_TEST_PASSED globals
  │   ├── reads: LOOP_COST_MILLICENTS, PREV_COST_MILLICENTS
  │   ├── writes: EFFICIENCY_SCORE, EFFICIENCY_PROGRESS, EFFICIENCY_PRODUCTIVITY, EFFICIENCY_COST
  │   └── writes: $LOG_DIR/efficiency.json (atomic, 12-field JSON for current iteration)
  ├── write_efficiency_history()              # NEW: appends to JSONL, emits event
  │   ├── appends: $LOG_DIR/efficiency-history.jsonl
  │   └── calls: emit_event "loop.efficiency" score=$SCORE iteration=$ITERATION
  ├── check_efficiency_abort()                # NEW: returns 1 if 3 consecutive low scores
  │   ├── reads: CONSECUTIVE_LOW_EFFICIENCY
  │   ├── sets: STATUS="efficiency_abort" on abort
  │   └── calls: emit_event "loop.efficiency_abort" on trigger
  └── _check_efficiency_trend_warning()       # NEW: warns on declining trend (no abort)
      └── calls: warn() if last 3 scores all < 50

State flow:
  initialize_state() → sets EFFICIENCY_SCORE=0, CONSECUTIVE_LOW_EFFICIENCY=0, PREV_TEST_PASSED="", PREV_COST_MILLICENTS=0
  write_state()      → persists efficiency_score, consecutive_low_efficiency to state file
  resume_state()     → restores efficiency globals from state file
  write_progress()   → adds "## Efficiency" section to progress.md
  show_summary()     → displays efficiency score in final summary box
```

### Storage Schemas

**`$LOG_DIR/efficiency.json`** (overwritten each iteration, atomic):

```json
{
  "iteration": 4,
  "timestamp": "2026-02-26T18:40:00Z",
  "score_composite": 65,
  "score_progress": 60,
  "score_productivity": 80,
  "score_cost": 100,
  "lines_changed": 23,
  "test_transition": "maintained_pass",
  "iteration_cost_millicents": 8500,
  "consecutive_low": 0,
  "status": "continuing",
  "trend": "stable"
}
```

**`$LOG_DIR/efficiency-history.jsonl`** (append-only, one JSON object per line per iteration):

```json
{"iteration":1,"score":38,"status":"continuing","ts":"2026-02-26T18:38:00Z"}
{"iteration":2,"score":65,"status":"continuing","ts":"2026-02-26T18:40:00Z"}
```

**State file additions** (key:value YAML in existing format):

```
efficiency_score: 65
consecutive_low_efficiency: 0
prev_test_passed: true
prev_cost_millicents: 8500
```

**`progress.md` new section** (after Status, before Recent Commits):

```markdown
## Efficiency

- Score: 65/100 (progress=60 productivity=80 cost=100)
- Consecutive low: 0/3
- Trend: stable
```

### Dashboard Integration

No `dashboard/server.ts` modifications required. Efficiency data flows through two existing channels:

1. `emit_event "loop.efficiency"` → `~/.shipwright/events.jsonl` (already consumed by dashboard's event stream)
2. `efficiency.json` in loop artifacts (already served by the dashboard's artifact file reader)

### Error Handling

- `jq` unavailable: skip efficiency JSON writes, still compute and display score in progress.md using printf
- `git diff` fails (no commits yet): progress score = 0, continue
- Division by zero guards: all denominators checked before arithmetic
- Missing `PREV_TEST_PASSED` (first iteration or resume): treat as neutral (score = 50)
- Corrupt `efficiency-history.jsonl`: ignore read errors, start fresh append

## Alternatives Considered

1. **Separate sourced library (`sw-loop-efficiency.sh`)** — Pros: cleaner separation, independent testing / Cons: introduces first `source` dependency in sw-loop.sh, breaks single-file deployment model, sed-extract test pattern doesn't apply, adds file to maintain. Rejected because the 4 functions are small (~120 lines total) and the inline approach preserves existing patterns.

2. **Test pass rate parsing (count PASS/FAIL lines in test output)** — Pros: finer-grained productivity signal / Cons: test output formats are heterogeneous (vitest, jest, pytest, go test all differ), parsing is fragile, `TEST_PASSED` boolean is the canonical signal. Rejected because the loop already normalizes test outcomes to a boolean; discrete state-transition scoring is more robust.

3. **Replace circuit breaker with efficiency scoring** — Pros: single mechanism, simpler / Cons: circuit breaker catches a different failure mode (zero code changes, stuck agent), efficiency scoring catches a different one (low-value changes). Both are needed. Rejected because they are complementary mechanisms.

4. **Machine learning / weighted history scoring** — Pros: could learn per-project thresholds / Cons: massive complexity, requires training data, bash integer arithmetic makes this impractical, over-engineered for the problem. Rejected as over-engineering.

5. **Dashboard-first approach (add API endpoints + UI)** — Pros: immediate visibility / Cons: scope creep into TypeScript, unnecessary when events.jsonl + progress.md already provide observability. Rejected to keep the feature focused; dashboard UI can be added later if needed.

## Implementation Plan

- **Files to create**: None
- **Files to modify**:
  - `scripts/sw-loop.sh` — 4 new functions (~120 lines), 6 function modifications (~40 lines of changes)
  - `scripts/sw-loop-test.sh` — 7 new test cases (~150 lines)
- **Dependencies**: None (uses existing `jq`, `git`, `emit_event`)
- **Risk areas**:
  - **`run_single_agent_loop()` call site ordering**: Efficiency check must run _after_ `check_progress()` (which updates `CONSECUTIVE_FAILURES`) and _before_ the next iteration's `check_circuit_breaker()`. Inserting at wrong position could cause double-abort or skipped scoring.
  - **Integer overflow in cost arithmetic**: `LOOP_COST_MILLICENTS` can reach millions for long loops. All intermediate calculations must stay within bash's 64-bit integer range. Guard: `$(( val > 10000000 ? 10000000 : val ))` caps at $100.
  - **State file backward compatibility**: Adding 4 new keys to the state file. `resume_state()` must handle state files that lack these keys (defaulting to zero/empty). Existing loops that resume from old state files must not break.
  - **`git diff --stat HEAD~1` on first commit**: No parent commit → git error. Guard with `git rev-parse HEAD~1 2>/dev/null` check.

## Validation Criteria

- [ ] `compute_iteration_efficiency()` returns correct composite score for known inputs: 3 files changed + fail→pass + $0.10 cost → score ≈ 72
- [ ] `compute_iteration_efficiency()` handles edge cases: 0 files changed → progress=0; no test cmd → productivity=50, cost=100; first iteration → neutral scores
- [ ] `check_efficiency_abort()` returns 0 (continue) when fewer than 3 consecutive low scores
- [ ] `check_efficiency_abort()` returns 1 (abort) after exactly 3 consecutive scores below 30, and sets `STATUS="efficiency_abort"`
- [ ] `check_efficiency_abort()` does not fire on iterations 1-2 (ramp-up grace period)
- [ ] `efficiency.json` is valid JSON with all 12 fields after each iteration
- [ ] `efficiency-history.jsonl` grows by exactly one line per iteration
- [ ] `emit_event "loop.efficiency"` fired with score and iteration on each iteration
- [ ] `emit_event "loop.efficiency_abort"` fired exactly once when abort triggers
- [ ] `progress.md` contains `## Efficiency` section with score, consecutive count, and trend
- [ ] `write_state()` persists and `resume_state()` restores all 4 new state keys
- [ ] Resuming from a state file without efficiency keys defaults gracefully (no errors)
- [ ] Existing circuit breaker and max-iteration logic unchanged — `npm test` passes with zero regressions
- [ ] `show_summary()` displays efficiency score in the summary box
- [ ] All new functions extractable via `sed -n '/^FUNC()/,/^}/p'` for unit testing
