# Plan: Pipeline Failure Auto-Diagnostic Report Generator

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change:** A new `shipwright diagnose` command that aggregates all existing failure data (pipeline state, error logs, root cause classification, memory patterns, vitals, loop errors) into a single structured diagnostic report — both human-readable markdown and machine-readable JSON.

**Implicit requirements:**
- Must work with partial data (not all pipelines produce all artifacts)
- Must be callable both manually and automatically from `daemon_on_failure()`
- Should surface actionable insights, not just raw data dumps
- Should integrate with the existing `observe` command group

**Acceptance criteria:**
1. `shipwright diagnose` generates a report from the most recent failed pipeline
2. `shipwright diagnose --issue N` targets a specific issue's failure data
3. Report includes: error timeline, root cause analysis, similar past failures, suggested fixes, health vitals at failure time
4. `--json` flag produces machine-readable output
5. Auto-invocation from daemon failure handler with report path in GitHub issue comment
6. Report persisted to `.claude/pipeline-artifacts/diagnostic-report.md`
7. Test suite passes with ≥15 test cases

### Alternatives Considered

**Approach A: Single monolithic script**
- One `sw-diagnose.sh` that reads all data sources and generates the report inline
- Pros: Simple, self-contained, easy to understand
- Cons: ~800+ lines, duplicates logic from existing modules (root-cause, memory, vitals), harder to test individual sections
- Blast radius: 1 new file + 2 minor edits (CLI router + daemon-failure)

**Approach B: Library + CLI pattern (CHOSEN)**
- Library functions in `scripts/lib/diagnostic-report.sh` for data collection and report assembly
- Thin CLI wrapper in `scripts/sw-diagnose.sh` for user interaction
- Pros: Reusable from daemon, tests, and CLI; follows established codebase pattern (every major feature has lib/ + CLI); individual sections are testable
- Cons: 2 new files instead of 1
- Blast radius: 2 new files + 3 minor edits (CLI router, daemon-failure, package.json)

**Approach C: Extend existing `sw-replay.sh`**
- Add a `diagnose` subcommand to the existing replay script
- Pros: No new files, builds on existing data reading code
- Cons: Replay is about viewing past runs; diagnostics is about analyzing failures. Different concerns. Would bloat replay from 542 → 900+ lines. Violates single-responsibility.
- Rejected: Wrong abstraction level

**Why Approach B:** It follows the exact pattern used by every other feature in this codebase (daemon-failure.sh, pipeline-state.sh, session-restart.sh are all lib modules consumed by CLI scripts). The library can be sourced by `daemon_on_failure()` without spawning a subprocess. The CLI wrapper handles argument parsing and display.

### Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Missing artifacts (no error-log.jsonl, no loop-logs) | Report has empty sections | Each section checks file existence and outputs "No data available" gracefully |
| Daemon integration slows failure handling | Delays retry spawn | Generate report asynchronously (background subshell), write path to state |
| Root-cause module not loaded in daemon context | Function not found errors | Source root-cause.sh with module guard (already has `_ROOT_CAUSE_LOADED` pattern) |
| Large error-log.jsonl (1000+ entries) | Slow parsing | Limit to last 50 entries (matches existing `rootcause_analyze_error_log` pattern) |
| jq not available | Report generation fails | Graceful fallback to basic grep-based extraction (matches doctor.sh pattern) |

### Dependency Analysis

**Depends on (read-only):**
- `scripts/lib/root-cause.sh` — `rootcause_classify()`, `rootcause_analyze_error_log()`
- `scripts/lib/error-actionability.sh` — `score_error_actionability()`
- `scripts/lib/pipeline-state.sh` — state file format (YAML frontmatter)
- `scripts/sw-memory.sh` — `memory_ranked_search()` (via subprocess call)
- `scripts/sw-pipeline-vitals.sh` — vitals data format (progress snapshots)
- `scripts/lib/helpers.sh` — `info()`, `error()`, `emit_event()`, color constants

**Modified by this change:**
- `scripts/sw` — add `diagnose` to CLI router (1 line in main case, 1 line in observe group)
- `scripts/lib/daemon-failure.sh` — add diagnostic report generation in `daemon_on_failure()` (5 lines)
- `package.json` — register test suite (1 line)

**Nothing depends on the new code** — purely additive.

---

## Files to Modify

### New Files
1. **`scripts/lib/diagnostic-report.sh`** — Library: data collection, section generators, report assembly (~350 lines)
2. **`scripts/sw-diagnose.sh`** — CLI: argument parsing, help, display, JSON output (~250 lines)
3. **`scripts/sw-diagnose-test.sh`** — Test suite (~400 lines)

### Modified Files
4. **`scripts/sw`** — Add `diagnose` command to CLI router (2 lines)
5. **`scripts/lib/daemon-failure.sh`** — Auto-generate report on failure (5 lines)
6. **`package.json`** — Register `sw-diagnose-test.sh` in test scripts

---

## Implementation Steps

### Step 1: Create `scripts/lib/diagnostic-report.sh`

The library module with these functions:

```
diag_collect_pipeline_state(project_root) → JSON
```
- Reads `.claude/pipeline-state.md` YAML frontmatter
- Extracts: status, current_stage, stage_statuses, stage_timings, last_error, error_class
- Returns structured JSON with pipeline metadata

```
diag_collect_error_log(artifacts_dir, max_entries) → JSON
```
- Reads `.claude/pipeline-artifacts/error-log.jsonl` (last N entries)
- Groups by error type, counts occurrences
- Scores each error via `score_error_actionability()`
- Returns JSON array with type distribution and top errors

```
diag_collect_loop_errors(project_root) → JSON
```
- Reads `.claude/loop-logs/error-summary.json`
- Reads `.claude/loop-logs/progress.md` for iteration context
- Returns JSON with iteration count, error lines, test status

```
diag_collect_root_cause(error_message, stage, exit_code) → JSON
```
- Calls `rootcause_classify()` for primary classification
- Calls `rootcause_analyze_error_log()` for pattern analysis
- Returns combined root cause assessment with confidence

```
diag_collect_similar_failures(query, repo_hash) → JSON
```
- Calls `memory_ranked_search()` with failure context as query
- Returns top 5 similar past failures with fix effectiveness

```
diag_collect_vitals(artifacts_dir) → JSON
```
- Reads latest progress snapshot from vitals data
- Computes health score at failure time if data available
- Returns health metrics (momentum, convergence, budget, error maturity)

```
diag_suggest_fixes(root_cause_json, similar_failures_json) → JSON
```
- Based on root cause category, suggests concrete next steps
- Incorporates fixes from similar past failures
- Prioritizes by fix effectiveness rate

```
diag_generate_report(project_root, issue_num, output_format) → string
```
- Orchestrates all collectors
- Assembles into markdown report (or JSON if format=json)
- Writes to `.claude/pipeline-artifacts/diagnostic-report.md`
- Returns report path

**Report structure:**
```markdown
# Pipeline Failure Diagnostic Report

## Summary
| Field | Value |
|-------|-------|
| Issue | #N |
| Failed Stage | build |
| Root Cause | code_bug (85% confidence) |
| Generated | 2026-03-08T12:34:56Z |

## Timeline
- 12:00:00 — intake: ✓ (2s)
- 12:00:02 — plan: ✓ (45s)
- 12:00:47 — build: ✗ (15m 23s)

## Root Cause Analysis
Category: code_bug
Confidence: 85%
Evidence:
- Test failure in build stage
- Non-zero exit code

## Error Details
### Top Errors (from error-log.jsonl)
| Type | Count | Example |
|------|-------|---------|
| test | 5 | AssertionError: expected true... |
| syntax | 1 | Unexpected token ... |

### Build Loop Errors (from error-summary.json)
Iteration: 15/20
Error lines:
- TypeError: Cannot read property 'name'...

## Similar Past Failures
1. [seen 3x] TypeError pattern — Fix: check null before access (effectiveness: 80%)

## Suggested Fixes
1. Check test assertions for incorrect expectations
2. Review null/undefined access patterns (similar to past fix)

## Health at Failure
Score: 42/100 (Critical)
Momentum: 15% — stalled
Convergence: declining
Budget: 65% remaining
```

### Step 2: Create `scripts/sw-diagnose.sh`

CLI wrapper:
- `shipwright diagnose` — latest failed pipeline
- `shipwright diagnose --issue N` — specific issue
- `shipwright diagnose --json` — JSON output
- `shipwright diagnose --worktree PATH` — diagnose from worktree
- `shipwright diagnose help` — usage

Pattern: follows `sw-replay.sh` / `sw-retro.sh` CLI structure.

Key implementation details:
- Source `lib/diagnostic-report.sh`
- Parse args (issue number, json flag, worktree path)
- Determine project root (worktree or current)
- Call `diag_generate_report()`
- Display report or output JSON
- Exit 0 on success, 1 if no failure data found

### Step 3: Integrate into CLI router (`scripts/sw`)

Add to main `case` block:
```bash
diagnose)
    exec "$SCRIPT_DIR/sw-diagnose.sh" "$@"
    ;;
```

Add to `route_observe()`:
```bash
diagnose)     exec "$SCRIPT_DIR/sw-diagnose.sh" "$@" ;;
```

Update help text for observe group.

### Step 4: Integrate into daemon failure handler

In `scripts/lib/daemon-failure.sh`, in `daemon_on_failure()` after the PM agent learn call (line ~338), before the GitHub comment section:

```bash
# Generate diagnostic report (non-blocking)
local diag_report_path=""
if [[ -f "$SCRIPT_DIR/lib/diagnostic-report.sh" ]]; then
    source "$SCRIPT_DIR/lib/diagnostic-report.sh" 2>/dev/null || true
    if [[ "$(type -t diag_generate_report 2>/dev/null)" == "function" ]]; then
        local diag_root="${WORKTREE_DIR:-${REPO_DIR}/.worktrees}/daemon-issue-${issue_num}"
        [[ ! -d "$diag_root/.claude" ]] && diag_root="$REPO_DIR"
        diag_report_path=$(diag_generate_report "$diag_root" "$issue_num" "markdown" 2>/dev/null || true)
    fi
fi
```

Then include the diagnostic summary in the existing GitHub issue comment body.

### Step 5: Create test suite (`scripts/sw-diagnose-test.sh`)

Following the test harness pattern from `sw-replay-test.sh`:
- Source `lib/test-helpers.sh`
- Mock binaries (git, gh, jq)
- Create fixture data (pipeline-state.md, error-log.jsonl, error-summary.json, progress.md)
- Test each collector function independently
- Test full report generation with complete data
- Test graceful handling of missing data
- Test JSON output mode
- Test CLI argument parsing
- Test help output

### Step 6: Register test in package.json

Add to scripts section:
```json
"test:diagnose": "bash scripts/sw-diagnose-test.sh"
```

---

## Task Decomposition

1. Create `scripts/lib/diagnostic-report.sh` with module guard, defaults, and helper sourcing — **no dependencies**
2. Implement `diag_collect_pipeline_state()` — parse pipeline-state.md YAML frontmatter — **depends on Task 1**
3. Implement `diag_collect_error_log()` — read/group/score error-log.jsonl entries — **depends on Task 1**
4. Implement `diag_collect_loop_errors()` — read error-summary.json and progress.md — **depends on Task 1**
5. Implement `diag_collect_root_cause()` — orchestrate root cause classification — **depends on Task 1**
6. Implement `diag_collect_similar_failures()` — query memory system for matching patterns — **depends on Task 1**
7. Implement `diag_collect_vitals()` — read health snapshots at failure time — **depends on Task 1**
8. Implement `diag_suggest_fixes()` — generate actionable fix suggestions from root cause + history — **depends on Task 1**
9. Implement `diag_generate_report()` — orchestrate all collectors into markdown/JSON report — **depends on Tasks 2-8**
10. Create `scripts/sw-diagnose.sh` CLI wrapper with arg parsing, help, display — **depends on Task 9**
11. Add `diagnose` to CLI router in `scripts/sw` (main case + observe group) — **depends on Task 10**
12. Integrate auto-generation into `daemon_on_failure()` in `scripts/lib/daemon-failure.sh` — **depends on Task 1**
13. Create `scripts/sw-diagnose-test.sh` test suite with ≥15 test cases — **depends on Tasks 1-10**
14. Register test in `package.json` — **depends on Task 13**
15. Verify all tests pass and report format is correct — **depends on Tasks 13-14**

Note: Tasks 2-8 are independent of each other and can be implemented in parallel. Task 12 only depends on Task 1 (not 9) because it sources the library directly.

---

## Task Checklist

- [ ] Task 1: Create `scripts/lib/diagnostic-report.sh` with module guard, defaults, helper sourcing
- [ ] Task 2: Implement `diag_collect_pipeline_state()` — parse pipeline-state.md YAML frontmatter
- [ ] Task 3: Implement `diag_collect_error_log()` — read/group/score error-log.jsonl entries
- [ ] Task 4: Implement `diag_collect_loop_errors()` — read error-summary.json and progress.md
- [ ] Task 5: Implement `diag_collect_root_cause()` — orchestrate root cause classification
- [ ] Task 6: Implement `diag_collect_similar_failures()` — query memory system for matching patterns
- [ ] Task 7: Implement `diag_collect_vitals()` — read health snapshots at failure time
- [ ] Task 8: Implement `diag_suggest_fixes()` — generate actionable fix suggestions
- [ ] Task 9: Implement `diag_generate_report()` — orchestrate collectors into markdown/JSON
- [ ] Task 10: Create `scripts/sw-diagnose.sh` CLI wrapper with arg parsing, help, display
- [ ] Task 11: Add `diagnose` to CLI router in `scripts/sw` (main case + observe group)
- [ ] Task 12: Integrate auto-generation into `daemon_on_failure()` in daemon-failure.sh
- [ ] Task 13: Create `scripts/sw-diagnose-test.sh` test suite with ≥15 test cases
- [ ] Task 14: Register test in `package.json`
- [ ] Task 15: Verify all tests pass and report format is correct

---

## Testing Approach

### Unit Tests (in `sw-diagnose-test.sh`)
1. **Help output** — verify usage text contains expected subcommands
2. **Pipeline state collection** — mock pipeline-state.md, verify JSON output structure
3. **Pipeline state missing** — no state file, verify graceful empty JSON
4. **Error log collection** — mock error-log.jsonl with varied types, verify grouping
5. **Error log empty** — no error log, verify graceful handling
6. **Loop error collection** — mock error-summary.json and progress.md, verify extraction
7. **Loop errors missing** — no loop-logs dir, verify graceful handling
8. **Root cause classification** — provide known error messages, verify categories
9. **Similar failures search** — mock memory files, verify ranked results
10. **Vitals collection** — mock progress snapshots, verify health data
11. **Fix suggestions** — verify suggestions match root cause category
12. **Full report generation** — provide all fixture data, verify markdown structure
13. **Full report with missing data** — empty artifacts dir, verify "No data" messages throughout
14. **JSON output mode** — verify valid JSON with all expected top-level keys
15. **Report file persistence** — verify file written to pipeline-artifacts/diagnostic-report.md
16. **Error log entry limit** — verify only last N entries processed (not unbounded)
17. **Issue-specific targeting** — `--issue N` resolves correct data directory
18. **Event emission** — verify `diagnose.report_generated` event emitted

### Integration Points
- Daemon integration tested via mock `daemon_on_failure()` call with fixture data
- CLI routing tested via `bash scripts/sw diagnose help`

---

## Definition of Done

- [ ] `shipwright diagnose` produces a readable diagnostic report from the latest failed pipeline
- [ ] `shipwright diagnose --issue N` targets a specific issue
- [ ] `shipwright diagnose --json` outputs valid, parseable JSON
- [ ] Report includes all 6 sections: summary, timeline, root cause, error details, similar failures, suggested fixes
- [ ] Each section degrades gracefully when data is missing (no crashes, shows "No data available")
- [ ] Daemon failure handler auto-generates report and includes summary in GitHub issue comment
- [ ] Report persisted to `.claude/pipeline-artifacts/diagnostic-report.md`
- [ ] Test suite has ≥15 passing tests
- [ ] All existing tests continue to pass (no regressions)
- [ ] Script follows project conventions: `set -euo pipefail`, Bash 3.2 compatible, VERSION variable, module guard, atomic writes
- [ ] `shipwright observe diagnose` alias works via route_observe
- [ ] Event emitted: `diagnose.report_generated` with issue number and report path
