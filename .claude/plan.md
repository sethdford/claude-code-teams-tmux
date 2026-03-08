# Design: Pipeline Failure Auto-Diagnostic Report Generator

## Context

When a Shipwright pipeline fails, operators must manually hunt across multiple artifact files (`error-log.jsonl`, `pipeline-state.md`, `events.jsonl`, memory `failures.json`) to understand what went wrong and what to do next. Each file uses a different format, and the failure-relevant data is interleaved with success data. The daemon's retry escalation logic (`daemon-failure.sh`) classifies failures for its own purposes but doesn't surface a human-readable or machine-parseable diagnostic to the operator.

**Constraints from the codebase:**
- All scripts are Bash 3.2 compatible (`set -euo pipefail`, no associative arrays, no `readarray`, no `${var,,}`)
- Every script carries a `VERSION="3.2.4"` variable kept in sync with `package.json`
- Existing libraries already perform root-cause classification (`lib/root-cause.sh`), error actionability scoring (`lib/error-actionability.sh`), pipeline state reading (`lib/pipeline-state.sh`), and memory search (`sw-memory.sh`) — but no single entry point aggregates them into a coherent report
- The pipeline failure path in `lib/pipeline-commands.sh` (around line 887-904) already performs memory capture and outcome analysis — the diagnostic call must slot in after these without disrupting them
- CLI commands are registered in `scripts/sw` via `case` statements using `exec "$SCRIPT_DIR/sw-<cmd>.sh" "$@"` pattern
- The project follows a one-script-per-feature pattern (see `sw-replay.sh`, `sw-retro.sh`, `sw-vitals.sh`)

## Decision

**Create a standalone `scripts/sw-diagnose.sh`** that aggregates data from existing libraries and artifact files, producing a structured 7-section diagnostic report in Markdown (terminal) or JSON (`--json`) format.

### Component Diagram

```
                    ┌─────────────────────────────────┐
                    │         scripts/sw (router)      │
                    │   diagnose|diagnostic → exec     │
                    └──────────────┬──────────────────┘
                                   │
                    ┌──────────────▼──────────────────┐
                    │      sw-diagnose.sh (NEW)        │
                    │  CLI entry + orchestrator        │
                    │  ─────────────────────────       │
                    │  1. Collect (read-only)          │
                    │  2. Classify (via libs)          │
                    │  3. Render (md or json)          │
                    └──┬──────┬──────┬──────┬─────────┘
                       │      │      │      │
          ┌────────────▼┐ ┌───▼────┐ ┌▼─────┴────┐ ┌──────────┐
          │ lib/         │ │ lib/   │ │ lib/       │ │ sw-      │
          │ root-cause.sh│ │ error- │ │ pipeline-  │ │ memory.sh│
          │              │ │ action-│ │ state.sh   │ │          │
          │ classify()   │ │ ability│ │ get_stage  │ │ search() │
          │ analyze()    │ │ score()│ │ _status()  │ │ query()  │
          └──────────────┘ └────────┘ └────────────┘ └──────────┘
                    ▲              ▲              ▲
                    │   READ-ONLY DATA SOURCES    │
          ┌─────────┴──────────────┴──────────────┴───────┐
          │  .claude/pipeline-state.md (YAML frontmatter) │
          │  .claude/pipeline-artifacts/error-log.jsonl    │
          │  .claude/pipeline-artifacts/error-summary.json │
          │  ~/.shipwright/events.jsonl                    │
          │  ~/.shipwright/memory/{hash}/failures.json     │
          └───────────────────────────────────────────────┘
```

### Data Flow

```
Request (CLI or auto-invoke)
  │
  ▼
Parse args (--json, --save, --quiet, --artifacts <dir>, --all)
  │
  ▼
diag_collect_pipeline_summary()
  ├─ Read pipeline-state.md YAML frontmatter
  └─ Extract: goal, template, branch, issue#, start_time, duration, final_status, failed_stage
  │
  ▼
diag_collect_stage_timeline()
  ├─ Parse stage_progress field from pipeline-state.md
  └─ Produce: array of {stage, status, duration} triples
  │
  ▼
diag_collect_errors()
  ├─ Read error-log.jsonl (last MAX_ERRORS entries, default 50)
  ├─ Group by error type (syntax, test, logic, runtime, dependency, etc.)
  └─ Produce: error groups with counts
  │
  ▼
diag_classify_root_cause()
  ├─ Source lib/root-cause.sh
  ├─ Call rootcause_classify() on aggregated error text
  └─ Produce: {classification, confidence_pct, evidence[], suggested_action}
  │
  ▼
diag_score_errors()
  ├─ Source lib/error-actionability.sh
  ├─ Call score_error_actionability() per error
  └─ Produce: errors ranked by actionability score (0-100)
  │
  ▼
diag_find_memory_matches()
  ├─ Call sw-memory.sh search with error signatures
  └─ Produce: array of {pattern, root_cause, fix, effectiveness_rate}
  │
  ▼
diag_generate_recommendations()
  ├─ Map root_cause classification → ordered action list
  ├─ Merge with memory fix suggestions
  └─ Produce: prioritized list of actionable next steps
  │
  ▼
Render (diag_render_markdown OR diag_render_json)
  │
  ▼
Output (stdout, or --save → pipeline-artifacts/diagnostic-report.{md,json})
  │
  ▼
emit_event "diagnostic.generated"
```

### Interface Contracts

```typescript
// === CLI Interface ===
// shipwright diagnose [options]
// Options:
//   --json              Output JSON instead of Markdown
//   --save              Write report to .claude/pipeline-artifacts/diagnostic-report.{md,json}
//   --quiet             Suppress terminal output (use with --save)
//   --artifacts <dir>   Override artifacts directory (default: .claude/pipeline-artifacts)
//   --all               Include all errors (not just last 50)
//   help                Show help text
// Exit codes: 0 = report generated, 1 = no artifacts found, 2 = usage error

// === Data Collection Functions ===

// diag_collect_pipeline_summary() → void
// Sets globals: DIAG_GOAL, DIAG_TEMPLATE, DIAG_BRANCH, DIAG_ISSUE,
//               DIAG_START_TIME, DIAG_DURATION, DIAG_STATUS, DIAG_FAILED_STAGE
// Reads: $STATE_FILE (.claude/pipeline-state.md)
// Error: Sets DIAG_STATUS="unknown" if state file missing

// diag_collect_stage_timeline() → void
// Sets global: DIAG_STAGES (newline-delimited "stage:status:duration" triples)
// Reads: $STATE_FILE stage_progress field
// Error: Sets DIAG_STAGES="" if no stage data

// diag_collect_errors() → void
// Sets globals: DIAG_ERROR_COUNT, DIAG_ERROR_GROUPS (JSON via jq),
//               DIAG_RAW_ERRORS (last $MAX_ERRORS lines from error-log.jsonl)
// Reads: $ERROR_LOG (.claude/pipeline-artifacts/error-log.jsonl)
// Error: Sets DIAG_ERROR_COUNT=0 if file missing/empty

// diag_classify_root_cause() → void
// Sets globals: DIAG_ROOT_CAUSE, DIAG_ROOT_CONFIDENCE, DIAG_ROOT_EVIDENCE,
//               DIAG_ROOT_ACTION
// Depends: lib/root-cause.sh::rootcause_classify()
// Error: Sets DIAG_ROOT_CAUSE="unknown", DIAG_ROOT_CONFIDENCE=0

// diag_score_errors() → void
// Sets global: DIAG_SCORED_ERRORS (JSON array of {error, score, category})
// Depends: lib/error-actionability.sh::score_error_actionability()
// Error: Returns empty array if scoring unavailable

// diag_find_memory_matches() → void
// Sets global: DIAG_MEMORY_MATCHES (JSON array of {pattern, root_cause, fix, rate})
// Depends: sw-memory.sh (subshell invocation)
// Error: Returns empty array if no matches or memory unavailable

// diag_generate_recommendations() → void
// Sets global: DIAG_RECOMMENDATIONS (newline-delimited action strings)
// Reads: DIAG_ROOT_CAUSE, DIAG_MEMORY_MATCHES
// Error: Produces generic "investigate error-log.jsonl" recommendation

// === Rendering Functions ===

// diag_render_markdown() → stdout
// Reads all DIAG_* globals, formats with Unicode box-drawing + colors
// Produces: 7-section Markdown report

// diag_render_json() → stdout
// Reads all DIAG_* globals, formats via jq
// Produces: JSON object with keys: summary, stages, errors, root_cause,
//           memory_matches, recommendations, artifacts

// === Integration Points ===

// Auto-invocation (pipeline-commands.sh, non-blocking):
//   bash "$SCRIPT_DIR/sw-diagnose.sh" --save --quiet 2>/dev/null || true
//
// Daemon reference (daemon-failure.sh, informational):
//   [[ -f "$diag_report" ]] && daemon_log INFO "Diagnostic report: $diag_report"
```

### Error Boundaries

| Component | Errors Handled | Propagation |
|-----------|---------------|-------------|
| `sw-diagnose.sh` (entry) | Missing artifact dir, missing state file, invalid args | Exit 1 with clear message; exit 2 for usage |
| `diag_collect_*` functions | Missing/empty files, malformed YAML/JSON | Set `DIAG_*` globals to safe defaults ("unknown", "", 0); never exit |
| `diag_classify_root_cause` | `lib/root-cause.sh` not found, `rootcause_classify()` fails | Falls back to `DIAG_ROOT_CAUSE="unknown"` with confidence 0 |
| `diag_score_errors` | `lib/error-actionability.sh` not found | Returns empty scored array; report shows raw errors without scores |
| `diag_find_memory_matches` | Memory system unavailable, no matches | Returns empty array; report shows "No historical matches" |
| `diag_render_json` | `jq` not installed | `check_jq` at CLI entry; if missing, suggest install and exit 1 |
| Pipeline auto-invoke | Any failure in diagnose | Wrapped in `|| true` — pipeline completion never blocked |
| Daemon reference | Report file missing | Conditional check `[[ -f ]]` — no log if absent |

**Key safety principle:** Every integration point is wrapped in `|| true` or conditional checks. A diagnostic failure must never block pipeline completion, daemon operation, or retry logic.

## Alternatives Considered

### 1. Extend `sw-replay.sh` with `replay diagnose` subcommand

**Pros:**
- Reuses existing event-reading and timeline-rendering code
- No new script file

**Cons:**
- Violates single-responsibility — replay shows *what happened* (timeline), diagnose explains *why it failed* (root cause analysis)
- Bloats `sw-replay.sh` (currently 542 lines) with unrelated logic
- Harder to test diagnostic functions in isolation
- `replay` reads from `events.jsonl` (timeline events); `diagnose` reads from `error-log.jsonl` + `pipeline-state.md` (failure artifacts) — different data sources

**Rejected because:** Conceptual mismatch. DVR playback and failure diagnosis are orthogonal concerns.

### 2. Extend `lib/audit-trail.sh` `audit_finalize()`

**Pros:**
- Already runs at pipeline completion — no new integration point needed
- Audit report is the natural place for a "what went wrong" section

**Cons:**
- Mixes auditing (compliance, completeness tracking) with diagnostics (failure investigation)
- Makes audit reports noisy for *successful* pipelines (would need conditional logic to suppress diagnostic sections on success)
- `audit_finalize()` is already complex; adding 200+ lines of diagnostic logic increases blast radius
- Audit reports are consumed by compound_quality stage — injecting diagnostic sections changes downstream expectations

**Rejected because:** Different audiences (auditor vs. operator) and different lifecycle (audit = every run, diagnose = failures only).

### 3. Inline diagnostic generation in `daemon-failure.sh`

**Pros:**
- Closest to where failure classification already happens
- No CLI routing needed

**Cons:**
- Only available in daemon mode — not usable interactively via `shipwright diagnose`
- `daemon-failure.sh` is a shared library sourced by `sw-daemon.sh` — adding I/O-heavy report generation violates its focused responsibility (classify + retry-decide)
- Can't produce standalone Markdown/JSON reports for operator consumption
- Not testable in isolation from daemon machinery

**Rejected because:** Limits diagnostic access to daemon-only context; defeats the "operator runs `shipwright diagnose` to investigate" use case.

## Implementation Plan

### Files to Create

| File | Lines (est.) | Purpose |
|------|-------------|---------|
| `scripts/sw-diagnose.sh` | ~450 | Diagnostic report generator — data collection, classification, rendering |
| `scripts/sw-diagnose-test.sh` | ~350 | 17 test cases covering all sections, edge cases, JSON validation |

### Files to Modify

| File | Change | Lines | Risk |
|------|--------|-------|------|
| `scripts/sw` | Add `diagnose\|diagnostic)` case in CLI router (near line 474, after `replay`) | +2 | None — append-only to case statement |
| `scripts/lib/pipeline-commands.sh` | Auto-invoke `sw-diagnose.sh --save --quiet` after memory capture (after line 904) | +4 | Low — wrapped in `|| true`, after existing failure handling |
| `scripts/lib/daemon-failure.sh` | Log diagnostic report path after failure classification (after line 198) | +2 | None — informational log, conditional on file existence |
| `package.json` | Register `sw-diagnose-test.sh` in npm test script | +1 | None — append to existing test chain |

### Dependencies

- **No new dependencies.** All required libraries already exist in the codebase.
- **Runtime deps:** `jq` (validated by `shipwright doctor`), `bash` 3.2+, standard POSIX utilities (`date`, `tail`, `head`, `sed`, `grep`)

### Risk Areas

| Risk | Impact | Likelihood | Mitigation |
|------|--------|-----------|------------|
| `rootcause_classify()` returns unexpected format | Report shows garbled root cause | Low — function is stable, used by daemon | Validate return structure; fall back to "unknown" |
| Large `error-log.jsonl` (>10K lines) | Slow `jq` processing, high memory | Medium — long-running daemon pipelines can accumulate | Default `MAX_ERRORS=50` with `--all` opt-in |
| Pipeline failure path regression | Pipeline exit/cleanup disrupted | Low | `|| true` wrapper; diagnose runs *after* all existing failure handling |
| State file format changes | Summary extraction breaks | Very Low — format is stable YAML frontmatter | Defensive `grep`/`sed` parsing with fallbacks |
| Test suite false-positives in CI | Flaky tests slow pipeline | Low | Mock all data sources; no external calls; deterministic fixtures |

## Validation Criteria

- [ ] `shipwright diagnose` produces readable Markdown report with all 7 sections when run against a failed pipeline's artifacts
- [ ] `shipwright diagnose --json` produces valid JSON (verified by `jq .` exit code 0) with keys: `summary`, `stages`, `errors`, `root_cause`, `memory_matches`, `recommendations`, `artifacts`
- [ ] `shipwright diagnose --save` writes `diagnostic-report.md` and `diagnostic-report.json` to `.claude/pipeline-artifacts/`
- [ ] Graceful degradation: running with no artifacts produces "No pipeline artifacts found" (exit 1), no crash
- [ ] Graceful degradation: empty `error-log.jsonl` produces report with "No errors recorded" section
- [ ] Graceful degradation: missing `lib/root-cause.sh` falls back to "unknown" classification without crashing
- [ ] Pipeline failure path auto-generates diagnostic report — verified by checking file existence after a failed pipeline run
- [ ] Auto-invocation is non-blocking — a deliberately broken `sw-diagnose.sh` does not prevent pipeline completion
- [ ] Daemon logs diagnostic report path on failure (visible in daemon log output)
- [ ] CLI router dispatches both `diagnose` and `diagnostic` aliases correctly
- [ ] Test suite has 17 test cases, all passing, covering: help output, no artifacts, empty errors, summary extraction, stage timeline, error classification, 4 root cause patterns, actionability scoring, memory matches, recommendations, JSON output, save artifacts, error limit, mixed error types
- [ ] Script passes `bash -n scripts/sw-diagnose.sh` (syntax check)
- [ ] No Bash 3.2 violations: no `declare -A`, `readarray`, `${var,,}`, `${var^^}`
- [ ] `VERSION` variable matches `package.json` version
- [ ] No GitHub API calls made during diagnostic generation (respects `$NO_GITHUB` / offline operation)
- [ ] `emit_event "diagnostic.generated"` fires on successful report generation (verifiable in `events.jsonl`)
