# Design: Failure Pattern Auto-Retry Intelligence System

## Context

Shipwright pipelines fail for many reasons — transient network errors, missing dependencies, API rate limits, disk space, and actual code bugs. Today, the codebase has **four separate, partially-overlapping failure handling mechanisms** that don't coordinate:

1. **`sw-pipeline.sh:classify_error()` (line 813)** — classifies errors as `infrastructure`, `logic`, `configuration`, or `unknown`. Used by `run_stage_with_retry()` (line 906) with exponential backoff (2^n, max 16s, with jitter).
2. **`sw-loop.sh:diagnose_failure()` (line 1120)** — pattern-matches 6 categories (`missing_import`, `type_error`, `logic_error`, `timeout_error`, `permission_error`, `resource_error`) and returns a strategy string. Tracks repeat counts but doesn't retry autonomously.
3. **`sw-memory.sh` (lines 360-559)** — stores failure patterns in `failures.json` with `seen_count`, `fix_effectiveness_rate`, and retrieval via `memory_query_fix_for_error()` / `memory_closed_loop_inject()`. Already wired into both loop (line 3011) and pipeline (line 1076).
4. **`scripts/lib/daemon-failure.sh`** — classifies daemon-level failures (`auth_error`, `api_error`, `invalid_issue`, `context_exhaustion`, `build_failure`) with per-class max retries and consecutive-failure auto-pause.

**Problem**: These four systems use different pattern sets, different classification schemes, and different retry strategies. A transient `ECONNREFUSED` may be classified as `infrastructure` by the pipeline, `timeout_error` by the loop, and `api_error` by the daemon — each with different retry behavior. There is no unified pattern library, no auto-fix capability, and no feedback loop that learns which retries actually succeed.

**Constraints**:

- Bash 3.2 compatible (no associative arrays, no `readarray`, no `${var,,}`)
- Atomic file writes (tmp + mv pattern, flock for concurrency)
- Must not break existing `self_healing_build_test()` or `run_stage_with_retry()` behavior
- Must work offline (`$NO_GITHUB` mode)
- Event-driven (`emit_event`) for auditability
- New scripts follow established conventions: `set -euo pipefail`, VERSION variable, ERR trap, helper fallbacks, subcommand routing

## Decision

**Unify failure classification under a single pattern library and extend existing retry infrastructure rather than building parallel systems.**

### Architecture: 3 New Scripts + 1 Data File (not 5 scripts)

The plan proposed 5 new scripts. After codebase analysis, **sw-retry-engine.sh is unnecessary** — `run_stage_with_retry()` in sw-pipeline.sh and the build loop in sw-loop.sh already implement exponential backoff retry. Instead, we enhance what exists.

```
                    .claude/failure-patterns.json
                         (unified pattern library)
                                  │
                                  ▼
                      sw-failure-detector.sh
                    (match → classify → recommend)
                          │           │
              ┌───────────┘           └──────────────┐
              ▼                                      ▼
     sw-autofix.sh                      sw-retry-intelligence.sh
   (execute safe fixes)               (learn, rank, generate patterns)
              │                                      │
              └──────────────┬───────────────────────┘
                             ▼
               Integration hooks into existing code:
          sw-loop.sh:diagnose_failure() — calls detector
          sw-pipeline.sh:classify_error() — calls detector
          sw-pipeline.sh:self_healing_build_test() — calls autofix
          sw-memory.sh — reads/writes pattern effectiveness
          lib/daemon-failure.sh — delegates to detector
```

### Data Flow

1. **Error occurs** → `post-tool-use.sh` writes to `error-log.jsonl` (existing) AND calls `detect_failure()` to enrich the entry with `pattern_id` and `category`
2. **Build loop** (`sw-loop.sh`) — `diagnose_failure()` now delegates to `sw-failure-detector.sh detect` instead of its inline pattern matching. Returns same interface (`category` + `strategy`) for backward compatibility.
3. **Pipeline retry** (`sw-pipeline.sh`) — `classify_error()` delegates to `sw-failure-detector.sh classify`. Maps detector categories to existing classes (`transient` → `infrastructure`, `permanent` → `logic`, `fixable` → `configuration` + trigger autofix).
4. **Auto-fix** — when detector returns `fixable`, `self_healing_build_test()` (line 996) calls `sw-autofix.sh apply <pattern_id> <context>` before the next build cycle. Autofix runs the whitelisted command, logs the result, and reports success/failure.
5. **Learning** — after each pipeline run, `sw-retry-intelligence.sh learn` processes `error-log.jsonl` entries tagged with outcomes. Updates `failure-patterns.json` with effectiveness rates. Generates new pattern candidates when a novel error recurs 3+ times with 80%+ retry success.
6. **Memory bridge** — `sw-memory.sh:memory_capture_failure()` (line 360) already stores patterns in `failures.json`. The intelligence layer reads from both `failures.json` (historical) and `failure-patterns.json` (curated library) to rank recommendations.

### Pattern Library Schema

```json
{
  "version": "1.0.0",
  "patterns": [
    {
      "id": "network-timeout",
      "name": "Network timeout (ETIMEDOUT)",
      "regex": "(ETIMEDOUT|getaddrinfo ETIMEDOUT|connect ETIMEDOUT)",
      "category": "transient",
      "autofix": null,
      "backoff_base_ms": 1000,
      "max_attempts": 3,
      "priority": 1,
      "stats": {
        "seen_count": 0,
        "retry_success": 0,
        "retry_fail": 0,
        "effectiveness": 0.0,
        "last_seen": null
      }
    }
  ]
}
```

**Categories**: `transient` (retry with backoff), `fixable` (apply fix then retry), `permanent` (fail immediately, log actionable error).

**Priority ordering**: When multiple patterns match, lowest priority number wins. Within same priority, highest `effectiveness` wins. This prevents overly broad patterns (e.g., "timeout" matching test assertion timeouts) from masking specific ones (e.g., "ETIMEDOUT").

### Auto-Fix Safety Model

Auto-fix commands are **whitelisted per pattern, not per command**. The pattern `npm-enoent` maps to `npm install`, `permission-denied` maps to `chmod +x <file>`. The autofix system:

1. Validates the fix command against a hardcoded allowlist: `npm install`, `npm ci`, `npm cache clean`, `git config`, `mkdir -p`, `chmod`, `export`
2. Refuses commands containing `rm`, `dd`, `curl | sh`, pipe to shell, or `sudo`
3. Runs with `--dry-run` first when the pattern has `effectiveness < 0.5` (untested fix)
4. Writes full audit entry to `error-log.jsonl` with `type: "autofix"`, command, outcome, and duration
5. Caps at 1 autofix attempt per pattern per pipeline run (prevents fix loops)

### Integration Strategy (Extend, Don't Replace)

**sw-loop.sh** (~30 lines changed):

- Replace inline pattern list in `diagnose_failure()` (lines 1129-1156) with call to `sw-failure-detector.sh detect "$error_output"`
- Keep existing return interface (`category` + `strategy` string) for backward compat
- Add autofix call before retry in the convergence loop (line 1207 area)

**sw-pipeline.sh** (~25 lines changed):

- Replace inline pattern list in `classify_error()` (lines 820-900) with call to `sw-failure-detector.sh classify "$error_output"`
- Map detector output to existing classes: `transient→infrastructure`, `fixable→configuration`, `permanent→logic`
- Add autofix trigger in `self_healing_build_test()` when classification is `fixable`

**lib/daemon-failure.sh** (~15 lines changed):

- Replace inline pattern list in `classify_failure()` with delegation to detector
- Keep existing `get_max_retries_for_class()` logic but source max_attempts from pattern library

**post-tool-use.sh** (~10 lines changed):

- After writing error-log entry, call detector to enrich with `pattern_id`
- Keep existing error type classification as fallback

**sw-memory.sh** (~40 lines added):

- `memory_record_retry_attempt(pattern_id, success, duration)` — update pattern stats
- `memory_get_retry_stats()` — aggregate retry metrics across all patterns
- Bridge between `failures.json` (memory system) and `failure-patterns.json` (pattern library)

### Metrics

Stored in `.claude/retry-metrics.json`, updated after each pipeline run:

```json
{
  "baseline_success_rate": 0.0,
  "current_success_rate": 0.0,
  "total_retries": 0,
  "successful_retries": 0,
  "autofixes_applied": 0,
  "autofixes_succeeded": 0,
  "measurement_start": "2026-02-26T00:00:00Z"
}
```

CLI: `shipwright retry metrics` (display), `shipwright retry patterns` (list patterns + effectiveness).

## Alternatives Considered

1. **Build 5 standalone scripts as planned** — Pros: clean separation, no risk to existing code / Cons: duplicates classify_error(), diagnose_failure(), run_stage_with_retry(), and memory_capture_failure(). Creates two parallel retry paths that could diverge. More code to maintain (~1900 lines vs ~1300 lines).

2. **Pure memory-based approach (extend sw-memory.sh only)** — Pros: minimal new files, leverages existing failure storage / Cons: memory system is designed for Claude-powered analysis (fills root_cause via LLM), not for fast regex-based classification. Pattern matching needs to be <50ms; memory queries involve JSON parsing of potentially large files. Conflates curated patterns with observed failures.

3. **Integrate into sw-intelligence.sh** — Pros: intelligence layer already caches analysis, has feature flags / Cons: intelligence requires Claude CLI (not always available), has 1-hour cache TTL (too slow for retry decisions), and is designed for pre-pipeline analysis, not real-time failure response.

## Implementation Plan

### Files to Create

| Path                                    | Purpose                                                             | Est. Lines |
| --------------------------------------- | ------------------------------------------------------------------- | ---------- |
| `.claude/failure-patterns.json`         | Unified pattern library with 20+ signatures                         | ~400       |
| `scripts/sw-failure-detector.sh`        | Detection engine: `detect`, `classify`, `match`, `list` subcommands | ~300       |
| `scripts/sw-autofix.sh`                 | Safe auto-fix: `apply`, `dry-run`, `whitelist`, `audit` subcommands | ~300       |
| `scripts/sw-retry-intelligence.sh`      | Learning: `learn`, `metrics`, `patterns`, `generate` subcommands    | ~350       |
| `scripts/sw-failure-detector-test.sh`   | 50+ test cases for detection accuracy                               | ~350       |
| `scripts/sw-autofix-test.sh`            | Whitelist enforcement, dry-run, audit trail                         | ~300       |
| `scripts/sw-retry-intelligence-test.sh` | Learning, effectiveness, pattern generation                         | ~300       |
| `.claude/retry-metrics.json`            | Metrics tracking (auto-created)                                     | ~20        |

### Files to Modify

| Path                             | Changes                                                           | Est. Lines Changed |
| -------------------------------- | ----------------------------------------------------------------- | ------------------ |
| `scripts/sw-loop.sh`             | `diagnose_failure()` delegates to detector, add autofix call      | ~30                |
| `scripts/sw-pipeline.sh`         | `classify_error()` delegates to detector, autofix in self-healing | ~25                |
| `scripts/lib/daemon-failure.sh`  | `classify_failure()` delegates to detector                        | ~15                |
| `.claude/hooks/post-tool-use.sh` | Enrich error-log entries with pattern_id                          | ~10                |
| `scripts/sw-memory.sh`           | Add retry stats functions, pattern bridge                         | ~40                |
| `scripts/sw`                     | Add `retry` subcommand routing                                    | ~5                 |
| `package.json`                   | Register 3 new test suites                                        | ~5                 |
| `.claude/CLAUDE.md`              | Document new commands, architecture                               | ~30                |

### Dependencies

- None new. Uses existing `jq`, `grep -E`, `flock`, `date`, standard POSIX tools.

### Risk Areas

| Risk                                                                             | Severity | Mitigation                                                                                                                                                                                        |
| -------------------------------------------------------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Broad regex patterns cause false positives (e.g., "timeout" matching test name)  | High     | Priority ordering + specificity requirement: patterns must include error-context keywords, not just the error word. Test with 50+ real error samples.                                             |
| Autofix `npm install` during build changes lock file, causes downstream failures | Medium   | Autofix only runs in fixable-classified failures. Lock file changes are git-committed by the build loop normally. Cap at 1 autofix per pattern per run.                                           |
| Modifying `classify_error()` in sw-pipeline.sh breaks existing retry behavior    | High     | Detector returns same interface (string classification). Fallback: if detector unavailable (script not found), use existing inline logic. Integration test specifically verifies backward compat. |
| Pattern library file corruption (concurrent pipeline writes)                     | Medium   | flock-based atomic writes (same pattern as sw-memory.sh line 394). Stats updates use tmp+mv.                                                                                                      |
| Intelligence layer generates bad patterns that cause retry storms                | Low      | 80% confidence threshold for auto-generated patterns. Max 3 attempts per pattern. Circuit breaker: if a pattern's effectiveness drops below 20%, it's auto-disabled.                              |

## Validation Criteria

- [ ] **Detection accuracy**: 50+ real error samples from existing error-log.jsonl files correctly classified with >95% accuracy
- [ ] **No false retries on permanent failures**: SyntaxError, TypeError, AssertionError never trigger retry
- [ ] **Transient retry success**: Simulated ETIMEDOUT/ECONNREFUSED/503 errors retry and succeed within 3 attempts
- [ ] **Auto-fix safety**: No command outside the allowlist can execute; dry-run mode produces no side effects
- [ ] **Backward compatibility**: `classify_error()` and `diagnose_failure()` return identical results for all existing error types when detector is loaded
- [ ] **Backward compatibility (fallback)**: When `sw-failure-detector.sh` is not on PATH, existing inline classification still works
- [ ] **Performance**: Pattern matching completes in <100ms for 1000 error strings (measured via test harness)
- [ ] **Concurrency safety**: Two parallel pipeline runs writing to failure-patterns.json don't corrupt the file
- [ ] **Metrics tracking**: After 10 pipeline runs with injected failures, `shipwright retry metrics` shows correct success rates
- [ ] **Learning**: After 5 occurrences of a novel error with 80%+ retry success, intelligence generates a new pattern candidate
- [ ] **All existing tests pass**: `npm test` succeeds with no regressions
- [ ] **New test suites pass**: 3 new test suites (detector, autofix, intelligence) with 50+ combined scenarios
