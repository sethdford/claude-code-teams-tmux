# Build Loop Behavior

The `shipwright loop` harness runs Claude Code in an iterative build loop (default 20 iterations, auto-extendable to ~35). This document describes the multi-layer stuck detection system that prevents wasted iterations.

## Detection Layers

### 1. Circuit Breaker (Low Progress)

**File:** `scripts/lib/loop-convergence.sh` — `check_progress()` / `check_circuit_breaker()`

Counts consecutive iterations with fewer than `MIN_PROGRESS_LINES` insertions. If the vitals-driven health score drops to "abort" level, or if the static threshold is exceeded, the loop exits with `STATUS="circuit_breaker"`.

### 2. Stuckness Detection (Soft Recovery)

**File:** `scripts/lib/loop-convergence.sh` — `detect_stuckness()`

7-signal heuristic checking text overlap, identical git diffs, error repetition, exit code patterns, diff size, and iteration budget usage. When 2+ signals fire, `STUCKNESS_COUNT` increments. After 3 detections, the loop triggers a **session restart** — a fresh Claude context window that reads progress from `progress.md`.

### 3. Zero-Progress Detection (Hard Abort)

**File:** `scripts/lib/loop-convergence.sh` — `detect_zero_progress()`

Detects when the agent is doing **nothing at all** — no commits, no test status change, no file modifications. This is the last line of defense against truly idle loops.

**Three signals (all must fire simultaneously):**

1. **No new commits** — `git rev-list --count HEAD` unchanged
2. **Test status unchanged** — `TEST_PASSED` value identical to prior iteration
3. **Working tree unchanged** — `git diff --stat HEAD` fingerprint (via md5sum) identical

**Behavior:**
- **Grace period:** Iterations 1-2 are skipped (agents may be analyzing/planning)
- **Threshold:** After `ZERO_PROGRESS_THRESHOLD` consecutive zero-progress iterations (default: 3), the loop aborts with `STATUS="stuck_zero_progress"`
- **Counter reset:** Any signal clearing (a commit, test change, or file modification) resets the counter to 0
- **Events:** `loop.zero_progress` emitted per detection, `loop.emergency_abort` on actual abort

## Configuration

| Flag / Config | Default | Purpose |
|---|---|---|
| `--zero-progress-threshold N` | `3` | Consecutive idle iterations before hard abort |
| `loop.zero_progress_threshold` | `3` | Same, via daemon-config.json |

## How the Layers Interact

```
Iteration completes
    │
    ├── convergence_integrate() → Can exit with SUCCESS (loop complete)
    │
    ├── guard_completion() → Can exit with SUCCESS (LOOP_COMPLETE found)
    │
    ├── check_progress() → Tracks CONSECUTIVE_FAILURES for circuit breaker
    │
    ├── detect_zero_progress() → Hard abort if nothing happening [NEW]
    │
    ├── detect_stuckness() → Soft restart if agent is trying but failing
    │
    └── Continue to next iteration
```

The ordering ensures:
- Convergence/completion checks run first — a successful loop exits before stuck detection
- Zero-progress runs before stuckness — if nothing happened, don't bother with soft recovery
- Stuckness detection is the final check — agent gets a fresh context window to try again
