# Plan: Pipeline Failure Auto-Diagnostic Report Generator

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change:** A new `shipwright diagnose` CLI command that, when a pipeline fails, automatically aggregates all failure data sources (error-log.jsonl, root-cause classifications, convergence history, pipeline state, vitals, stall detection, memory patterns) into a single, structured diagnostic report. The report should be human-readable (terminal) and machine-readable (JSON), and should be auto-generated at pipeline failure time.

**Implicit requirements:**
- Must work with existing data sources — no new data collection needed
- Should integrate into the pipeline failure path so reports are generated automatically (not just on-demand)
- Should surface actionable remediation suggestions (leveraging existing `rootcause_suggest_fix()` and `error-actionability` scoring)
- Should support `--json` flag for programmatic consumption (daemon, dashboard)
- Must respect `$NO_GITHUB` for offline/local mode

**Acceptance criteria:**
1. `shipwright diagnose` produces a structured report from pipeline artifacts
2. Reports are auto-generated on pipeline failure (saved to `.claude/pipeline-artifacts/diagnostic-report.md` and `.json`)
3. Report includes: failure timeline, root cause classification, error actionability scores, convergence status, vitals snapshot, memory matches, and remediation suggestions
4. `--json` flag outputs machine-readable JSON
5. Test suite passes with ≥15 test cases covering all report sections
6. Daemon failure handler references the diagnostic report in GitHub issue comments

### Alternatives Considered

**Approach A: Standalone script + pipeline hook (CHOSEN)**
- New `scripts/sw-diagnose.sh` with a library module `scripts/lib/diagnostic-report.sh`
- Hook into `pipeline-commands.sh` failure path to auto-generate
- Pros: Minimal blast radius, reuses all existing infrastructure, follows established script patterns
- Cons: Adds one new script file

**Approach B: Extend `rootcause_report()` in `lib/root-cause.sh`**
- Expand the existing report function to aggregate more data sources
- Pros: No new files
- Cons: Violates single responsibility — root-cause.sh handles classification, not aggregation. Would make the module too large and tightly coupled to pipeline artifacts, vitals, convergence, etc.

**Approach C: Add to `sw-retro.sh` retrospective engine**
- Extend sprint retrospectives with per-pipeline failure reports
- Pros: Reuses existing analysis framework
- Cons: Retro is sprint-level (multi-pipeline), not per-failure. Wrong abstraction level.

**Decision: Approach A** — cleanest separation of concerns. A dedicated diagnostic module aggregates data from existing subsystems without modifying them. The pipeline failure path calls it as a post-failure hook, same pattern as memory capture and skill outcome analysis.

### Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Missing data sources (empty files) | Report shows blank sections | Graceful degradation — each section checks file existence, shows "No data available" |
| Performance on large error logs | Slow report generation | Cap JSONL reads to last 100 entries; use `tail` + `jq` streaming |
| Breaking pipeline failure path | Pipeline hangs on report generation | All diagnostic calls wrapped in `2>/dev/null || true` — non-blocking |
| Bash 3.2 compatibility | Script fails on macOS | Follow existing patterns: no associative arrays, no readarray, no ${var,,} |

### Dependency Analysis

**Depends on (read-only — no modifications needed):**
- `lib/root-cause.sh` — `rootcause_classify()`, `rootcause_suggest_fix()`
- `lib/error-actionability.sh` — `score_error_actionability()`, `erract_deduplicate()`
- `lib/convergence.sh` — convergence history JSON
- `sw-pipeline-vitals.sh` — vitals snapshot JSON
- `sw-stall-detector.sh` — stall detection JSON
- `sw-memory.sh` — failure pattern search
- `lib/pipeline-state.sh` — stage statuses and timings
- `lib/helpers.sh` — output helpers, `emit_event()`, `now_iso()`

**Modified by this change:**
- `scripts/sw` — Add `diagnose` command routing (1 line)
- `scripts/lib/pipeline-commands.sh` — Add diagnostic report generation call in failure path (~5 lines)
- `scripts/lib/daemon-failure.sh` — Reference diagnostic report in GitHub comments (~3 lines)

**No circular dependency risk** — diagnostic module only reads from existing subsystems, nothing depends on it.

---

## Files to Modify

### New Files
1. **`scripts/sw-diagnose.sh`** (~500 lines) — CLI entry point for `shipwright diagnose`
2. **`scripts/lib/diagnostic-report.sh`** (~400 lines) — Core diagnostic report library (data aggregation, formatting)
3. **`scripts/sw-diagnose-test.sh`** (~350 lines) — Test suite

### Modified Files
4. **`scripts/sw`** — Add `diagnose` case to command router (~1 line)
5. **`scripts/lib/pipeline-commands.sh`** — Call diagnostic report on pipeline failure (~5 lines)
6. **`scripts/lib/daemon-failure.sh`** — Include diagnostic report path in failure comments (~3 lines)
7. **`package.json`** — Register test suite in test runner (~1 line)
8. **`.claude/CLAUDE.md`** — Add `diagnose` to command table, add to runtime state section

---

## Implementation Steps

### Step 1: Create `scripts/lib/diagnostic-report.sh` (core library)

The library module that aggregates all data sources into a structured diagnostic report. Functions:

```
diag_generate_report()        — Main entry: collects all sections, outputs report
diag_collect_timeline()       — Build failure event timeline from error-log.jsonl + events.jsonl
diag_collect_root_cause()     — Run rootcause_classify() on last error, aggregate error-log analysis
diag_collect_convergence()    — Read convergence-history.json, detect patterns (stalled/diverging/oscillating)
diag_collect_vitals()         — Read pipeline vitals snapshot (health score, momentum, convergence, budget)
diag_collect_errors()         — Deduplicate + score errors from error-log.jsonl using error-actionability
diag_collect_memory_matches() — Search memory system for matching failure patterns + known fixes
diag_collect_stall_info()     — Run stall detector against current pipeline state
diag_collect_stage_timings()  — Extract per-stage duration from pipeline-state.md
diag_format_terminal()        — Render report with Unicode box-drawing, colors, sections
diag_format_json()            — Output structured JSON with all sections
diag_save_report()            — Write to pipeline-artifacts/ (both .md and .json)
```

**Key design decisions:**
- Each `diag_collect_*` function returns a JSON object via stdout — composable
- `diag_generate_report()` merges all JSON objects into one with `jq -s 'add'`
- Terminal format uses existing color constants and output helpers
- Library is source-able (guarded with `_DIAGNOSTIC_REPORT_LOADED`)

### Step 2: Create `scripts/sw-diagnose.sh` (CLI entry point)

Subcommands:
- `shipwright diagnose` (default) — Generate report for current pipeline artifacts
- `shipwright diagnose --json` — JSON output
- `shipwright diagnose --artifacts <dir>` — Custom artifacts directory
- `shipwright diagnose --issue <N>` — Find artifacts for a specific issue pipeline
- `shipwright diagnose last` — Diagnose most recent failed pipeline
- `shipwright diagnose help` — Usage

Structure follows existing script conventions:
- `set -euo pipefail`
- `VERSION="3.2.4"`
- Source `lib/helpers.sh`, `lib/diagnostic-report.sh`
- Standard `info()/success()/warn()/error()` output
- `emit_event "diagnostic.generated"` on completion

### Step 3: Wire into CLI router (`scripts/sw`)

Add to the command case statement:
```bash
diagnose)
    exec "$SCRIPT_DIR/sw-diagnose.sh" "$@"
    ;;
```

### Step 4: Hook into pipeline failure path (`scripts/lib/pipeline-commands.sh`)

In the failure branch (around line 873, after memory capture), add:
```bash
# Generate auto-diagnostic report
if [[ -f "$SCRIPT_DIR/lib/diagnostic-report.sh" ]]; then
    source "$SCRIPT_DIR/lib/diagnostic-report.sh"
    diag_generate_report "$ARTIFACTS_DIR" "$STATE_FILE" "${CURRENT_STAGE_ID:-unknown}" 2>/dev/null || true
fi
```

This generates both `.claude/pipeline-artifacts/diagnostic-report.md` and `diagnostic-report.json` automatically on every pipeline failure.

### Step 5: Reference diagnostic report in daemon failure comments (`scripts/lib/daemon-failure.sh`)

In `daemon_on_failure()`, when posting the GitHub comment on failure, append a note about the diagnostic report:
```bash
# After the existing comment body
body+=$'\n\n'"📋 Diagnostic report: \`.claude/pipeline-artifacts/diagnostic-report.md\`"
```

### Step 6: Create test suite (`scripts/sw-diagnose-test.sh`)

Test cases covering:
1. Report generation with all data sources present
2. Report generation with missing data sources (graceful degradation)
3. Timeline construction from error-log.jsonl
4. Root cause classification integration
5. Convergence status extraction
6. Error deduplication and actionability scoring
7. Memory pattern matching
8. Stage timing extraction from pipeline-state.md
9. JSON output format validation
10. Terminal output format validation
11. Custom artifacts directory flag
12. Empty pipeline artifacts (no errors at all)
13. Large error log handling (100+ entries)
14. Report file persistence (both .md and .json written)
15. Event emission on report generation

### Step 7: Register test suite and update documentation

- Add `sw-diagnose-test.sh` to `package.json` test scripts
- Add `diagnose` command to CLAUDE.md command tables
- Add `diagnostic-report.md` and `diagnostic-report.json` to runtime state section

---

## Task Checklist

- [ ] Task 1: Create `scripts/lib/diagnostic-report.sh` — core library with all `diag_*` functions for data collection, aggregation, and formatting
- [ ] Task 2: Create `scripts/sw-diagnose.sh` — CLI entry point with subcommands (default, --json, --artifacts, last, help)
- [ ] Task 3: Add `diagnose` route to `scripts/sw` CLI router
- [ ] Task 4: Hook `diag_generate_report()` into pipeline failure path in `scripts/lib/pipeline-commands.sh`
- [ ] Task 5: Add diagnostic report reference to daemon failure GitHub comments in `scripts/lib/daemon-failure.sh`
- [ ] Task 6: Create `scripts/sw-diagnose-test.sh` test suite with ≥15 test cases
- [ ] Task 7: Register test in `package.json` and update CLAUDE.md documentation tables

---

## Diagnostic Report Structure

### Terminal Output (diagnostic-report.md)

```
═══════════════════════════════════════════════════════════════════════════
                 Pipeline Failure Diagnostic Report
═══════════════════════════════════════════════════════════════════════════

Pipeline: pipeline-42
Goal:     Add user authentication
Failed:   2026-03-08T05:20:38Z
Duration: 12m34s
Template: standard

─── Failed Stage ────────────────────────────────────────────────────────
  Stage:   build (iteration 3 of 10)
  Status:  failed
  Duration: 8m12s

─── Root Cause Analysis ─────────────────────────────────────────────────
  Category:   code_bug (85% confidence)
  Evidence:   AssertionError: Expected 'foo' but got 'bar'
  Suggestion: Fix the failing assertion in src/auth.test.ts

─── Error Timeline ──────────────────────────────────────────────────────
  05:15:22  [test]       npm test -- auth.test.ts (exit 1)
  05:17:45  [test]       npm test -- auth.test.ts (exit 1)
  05:19:30  [dependency] npm install passport (exit 1)

─── Error Summary (3 unique errors, 5 total) ────────────────────────────
  [85/100] src/auth.test.ts:42 — AssertionError: Expected 'foo'...
  [72/100] src/auth.ts:15 — TypeError: Cannot read property...
  [45/100] npm ERR! peer dep mismatch (needs enhancement)

─── Convergence Status ──────────────────────────────────────────────────
  Status:  diverging (3 declining iterations)
  Scores:  72 → 65 → 58
  Trend:   ▼ declining

─── Pipeline Vitals ─────────────────────────────────────────────────────
  Health:     42/100 (intervene)
  Momentum:   35/100
  Convergence: 28/100
  Budget:     85/100
  Error:      38/100

─── Stage Timings ───────────────────────────────────────────────────────
  intake:  0m15s  ✓
  plan:    1m22s  ✓
  build:   8m12s  ✗ ← failed here
  test:    —      skipped

─── Known Patterns (from memory) ────────────────────────────────────────
  Match: "AssertionError in auth" (seen 3x, fix effectiveness: 85%)
  Fix:   "Add missing import for passport middleware"

─── Remediation Suggestions ─────────────────────────────────────────────
  1. Fix the failing test assertion in src/auth.test.ts:42
  2. Resolve npm peer dependency conflict
  3. Consider using --max-restarts 2 to allow session recovery

═══════════════════════════════════════════════════════════════════════════
```

### JSON Output (diagnostic-report.json)

```json
{
  "generated_at": "2026-03-08T05:20:38Z",
  "pipeline": {
    "name": "pipeline-42",
    "goal": "Add user authentication",
    "template": "standard",
    "duration_s": 754,
    "status": "failed",
    "failed_stage": "build",
    "issue_number": 42
  },
  "root_cause": {
    "category": "code_bug",
    "confidence": 85,
    "evidence": ["AssertionError: Expected 'foo' but got 'bar'"],
    "suggestion": "Fix the failing assertion in src/auth.test.ts"
  },
  "timeline": [
    {"timestamp": "...", "type": "test", "command": "npm test", "exit_code": 1, "error": "..."}
  ],
  "errors": {
    "total": 5,
    "unique": 3,
    "entries": [
      {"message": "...", "type": "test", "actionability_score": 85, "file": "src/auth.test.ts", "line": 42}
    ]
  },
  "convergence": {
    "status": "diverging",
    "scores": [72, 65, 58],
    "iterations": 3
  },
  "vitals": {
    "health_score": 42,
    "verdict": "intervene",
    "momentum": 35,
    "convergence": 28,
    "budget": 85,
    "error_maturity": 38
  },
  "stage_timings": [
    {"stage": "intake", "duration_s": 15, "status": "complete"},
    {"stage": "build", "duration_s": 492, "status": "failed"}
  ],
  "memory_matches": [
    {"pattern": "AssertionError in auth", "seen_count": 3, "fix": "Add missing import", "effectiveness": 85}
  ],
  "remediation": [
    "Fix the failing test assertion in src/auth.test.ts:42",
    "Resolve npm peer dependency conflict",
    "Consider using --max-restarts 2 to allow session recovery"
  ]
}
```

---

## Testing Approach

1. **Unit tests** — Each `diag_collect_*` function tested independently with mock data in temp directories
2. **Integration test** — Full `diag_generate_report()` with realistic pipeline artifacts
3. **Edge cases** — Empty files, missing files, malformed JSON, very large error logs
4. **Output format** — JSON output validated with `jq` for structure; terminal output checked for key sections
5. **CLI tests** — `sw-diagnose.sh` subcommands (help, --json, --artifacts, last)
6. **Mock pattern** — Follow existing test harness: mock binaries in temp PATH, PASS/FAIL counters, ERR trap

Test command: `bash scripts/sw-diagnose-test.sh`

---

## Definition of Done

- [ ] `shipwright diagnose` generates a complete diagnostic report from pipeline artifacts
- [ ] `shipwright diagnose --json` outputs valid, structured JSON
- [ ] Reports are auto-generated on pipeline failure (written to `.claude/pipeline-artifacts/`)
- [ ] Report covers all 8 sections: pipeline info, root cause, timeline, errors, convergence, vitals, stage timings, memory matches, remediation
- [ ] Graceful degradation when data sources are missing (no crashes, shows "No data available")
- [ ] Daemon failure comments reference the diagnostic report
- [ ] Test suite has ≥15 passing test cases
- [ ] All existing tests still pass (`npm test`)
- [ ] Bash 3.2 compatible (no associative arrays, no readarray, no ${var,,})
- [ ] `$NO_GITHUB` respected in all GitHub-dependent paths
- [ ] CLAUDE.md updated with new command and runtime state entries

---

## Task Decomposition (with dependencies)

1. **Task 1: Create `lib/diagnostic-report.sh`** — No dependencies. Core library.
2. **Task 2: Create `sw-diagnose.sh`** — Depends on Task 1 (sources the library).
3. **Task 3: Add CLI route** — Depends on Task 2 (routes to the script).
4. **Task 4: Pipeline failure hook** — Depends on Task 1 (calls library functions). Independent of Tasks 2-3.
5. **Task 5: Daemon failure reference** — Depends on Task 4 (report must exist to reference).
6. **Task 6: Test suite** — Depends on Tasks 1-2 (tests the library and CLI). Can be developed in parallel with Tasks 3-5.
7. **Task 7: Documentation** — Depends on all above being complete.

**Parallelizable:** Tasks 3, 4, 5 are independent of each other (all depend only on Task 1 or 2). Task 6 can start after Task 1.

---

## Risk Analysis

| Risk | What Could Break | Mitigation |
|------|-----------------|------------|
| Pipeline failure path regression | Adding diagnostic call could slow down or error in the failure handler | Wrap in `2>/dev/null \|\| true` — fully non-blocking. Test with mock pipeline artifacts. |
| Large error-log.jsonl causes OOM | `jq -s` loads entire file into memory | Cap reads with `tail -100` before piping to jq. Use streaming `jq` where possible. |
| Root cause module not loaded | `rootcause_classify` may not be available if lib not sourced | Check `type rootcause_classify >/dev/null 2>&1` before calling; degrade gracefully. |
| Daemon comment too long | GitHub API rejects comments over 65536 chars | Only add 1-line reference to report file path, not inline the report. |
| Bash 3.2 compat | macOS default bash | No associative arrays, no `readarray`, use `while read` with process substitution. Follow existing patterns in codebase. |
