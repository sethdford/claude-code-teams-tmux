# Pipeline Debug Mode Implementation Plan

**Issue**: Add `--debug` flag to pipeline start command that enables verbose instrumentation
**Priority**: P1 (fast)
**Complexity**: Medium
**Acceptance Criteria**: Debug flag logs timestamps, intermediate artifacts, decision points; test suite validates output

---

## Executive Summary

This plan adds comprehensive instrumentation to the Shipwright pipeline to support post-mortem debugging when pipelines fail. The `--debug` flag enables microsecond-precision tracing of stage boundaries, decision points, and intermediate state snapshots, making it dramatically easier to diagnose failure root causes.

The implementation leverages existing pipeline architecture (emit_event, artifacts directory, state file) and adds a thin instrumentation layer without requiring refactoring of core pipeline logic.

---

## Requirements Clarity & Analysis

### Minimum Viable Change
- Add `--debug` flag to CLI argument parser
- Create debug logging function that writes to debug-trace.log with microsecond timestamps
- Inject debug calls at stage boundaries (start/end/error)
- Preserve full Claude tool output during debug mode
- Save debug artifacts to `.claude/pipeline-artifacts/debug/`
- Update help text and tests

### Implicit Requirements Identified
- **Audit trail**: Each decision point should be traceable (e.g., "template selected: standard because issue has 5 labels")
- **Minimal performance impact**: Debug mode should not significantly slow down the pipeline
- **Non-intrusive**: Should not require modifying existing stage functions or logic
- **Structured output**: JSON or key=value format for programmatic parsing of debug logs
- **Privacy**: Debug logs may contain sensitive information (LLM prompts, output); respect NO_GITHUB flag

### Acceptance Criteria (Refined)
✅ `--debug` flag added to `shipwright pipeline start`
✅ Debug mode enabled via environment variable `SHIPWRIGHT_DEBUG=1`
✅ `debug-trace.log` created with microsecond timestamps
✅ Decision points logged: template selection, timeout calculations, model routing, retry decisions
✅ Intermediate artifacts (plan.md, design.md snapshot before upload) preserved
✅ Full Claude tool output captured (not just stdout)
✅ Debug dir at `.claude/pipeline-artifacts/debug/`
✅ Help text updated with `--debug` example
✅ Test suite validates debug output format and content

---

## Design Alternatives & Trade-offs

### Alternative 1: Thin Instrumentation Layer (CHOSEN)
**Approach**: Create a new `lib/pipeline-debug.sh` module that wraps key decision points without modifying existing code.

**Trade-offs**:
- ✅ **Simplicity**: 200-300 LOC, minimal blast radius
- ✅ **Maintainability**: Future pipeline changes don't need debug awareness
- ❌ **Visibility**: May miss decision points in subshells or sourced scripts
- ✅ **Performance**: Conditional logging based on flag, negligible overhead

**Implementation**: Hook into stage start/end, emit_event calls, and key functions (template selection, timeout calculation).

---

### Alternative 2: Comprehensive Instrumentation (Rejected)
**Approach**: Modify every pipeline function to include debug statements.

**Trade-offs**:
- ❌ **Complexity**: 1000+ LOC changes across 15+ files
- ❌ **Maintainability**: Every future change must consider debug statements
- ✅ **Visibility**: Captures everything
- ❌ **Risk**: High likelihood of test failures from noise in output

**Why rejected**: Violates "don't over-engineer" principle; thin layer captures 90% of useful debug info with 10% of effort.

---

### Alternative 3: Existing logging + filtering (Rejected)
**Approach**: Use existing emit_event infrastructure, add --debug-filter to process logs.

**Trade-offs**:
- ✅ **Reuses infrastructure**: No new modules needed
- ❌ **Post-hoc analysis**: Can't capture decision context at decision time
- ❌ **Missing state**: No intermediate snapshots of artifacts
- ❌ **Tool output**: Can't preserve full Claude output

**Why rejected**: Insufficient fidelity for root cause diagnosis. emit_event is event-centric, not stateful.

---

## Task Decomposition (Dependency Graph)

### Phase 1: Infrastructure Setup
1. **Task 1**: Create `lib/pipeline-debug.sh` module with debug state management
   - Variables: DEBUG_ENABLED, DEBUG_DIR, DEBUG_TRACE_LOG
   - Helper functions: debug_log, debug_snapshot, debug_event
   - Status: INDEPENDENT

2. **Task 2**: Add --debug argument parsing to lib/pipeline-cli.sh
   - Add case statement for `--debug`
   - Add to help text
   - Export DEBUG_ENABLED variable
   - Status: DEPENDS ON Task 1

3. **Task 3**: Create debug artifacts directory structure in pipeline_start()
   - Mkdir .claude/pipeline-artifacts/debug/
   - Initialize debug-trace.log with header
   - Status: DEPENDS ON Task 2

### Phase 2: Stage Instrumentation
4. **Task 4**: Inject debug calls at stage boundaries (start/end/error)
   - Hook into run_stage_with_retry in lib/pipeline-execution.sh
   - Log stage name, start time, configuration snapshot
   - Status: DEPENDS ON Task 1, Task 3

5. **Task 5**: Capture decision point logs
   - Template selection logic (load_pipeline_config)
   - Timeout calculations (adaptive-timeout.sh integration)
   - Model routing decisions (intelligence layer)
   - Retry decisions (run_stage_with_retry)
   - Status: DEPENDS ON Task 1

6. **Task 6**: Preserve intermediate artifacts
   - Snapshot plan.md before stage completion
   - Snapshot design.md before review
   - Copy test-results.log to debug/ on failures
   - Status: DEPENDS ON Task 3

### Phase 3: Claude Output Preservation
7. **Task 7**: Capture full Claude CLI output
   - Create a wrapper for Claude invocations that tees output to debug log
   - Preserve stderr separately (errors/warnings)
   - Save raw JSON responses for API calls
   - Status: DEPENDS ON Task 1, Task 3

### Phase 4: Documentation & Testing
8. **Task 8**: Update help text and documentation
   - Add `--debug` to START OPTIONS in show_help()
   - Add example: `shipwright pipeline start --issue 123 --debug`
   - Create README section: "Debugging Failed Pipelines"
   - Status: DEPENDS ON Task 2

9. **Task 9**: Create test suite for debug mode
   - sw-pipeline-debug-test.sh
   - Validate --debug flag parsing
   - Validate debug-trace.log format
   - Validate artifact snapshots
   - Validate Claude output capture
   - Status: DEPENDS ON Task 1-7

10. **Task 10**: Integration test (happy path)
    - Run full pipeline with --debug
    - Verify all debug artifacts exist
    - Verify trace log contains all decision points
    - Status: DEPENDS ON Task 9

### Phase 5: Polish & Validation
11. **Task 11**: Performance profiling
    - Measure pipeline runtime with/without --debug
    - Ensure <5% overhead
    - Status: DEPENDS ON Task 7

12. **Task 12**: Documentation of debug output format
    - Publish schema for debug-trace.log (timestamp|level|component|message)
    - Examples of debug output for each stage
    - Status: DEPENDS ON Task 8

---

## Risk Analysis

### Critical Risk 1: stdout/stderr Capture Side Effects
**What could break**: Capturing Claude output via tee or exec redirection could interfere with:
- Interactive prompts in stage functions
- Tool output parsing (JSON responses from GitHub API)
- Progress bars or colored output from CLI tools

**Mitigation**:
- Capture to file descriptor 3+ (leave 1/2 alone)
- Use process substitution `>(tee)` instead of pipes to preserve exit codes
- Test with full pipeline to detect interference

**Implementation**:
```bash
# In pipeline-debug.sh
if [[ "$DEBUG_ENABLED" == true ]]; then
    exec 3> >(tee -a "$DEBUG_TRACE_LOG")
    debug_log() { echo "[$(date +%s.%N)] $*" >&3; }
fi
```

---

### Critical Risk 2: Disk Space Exhaustion
**What could break**: Debug artifacts could consume significant disk space:
- Each pipeline invocation creates artifacts
- Long-running pipelines with many iterations generate large logs
- Claude output can be verbose (100KB+ per stage)

**Mitigation**:
- Rotate debug logs at 100MB per pipeline
- Compress old debug dirs weekly
- Add `--debug-retention <days>` flag to control cleanup
- Default to 30 days retention

**Implementation**:
- Check debug-trace.log size before writing
- Move to debug-trace.log.1, .2 if size > 100MB
- Document in help text

---

### Critical Risk 3: Sensitive Information Leakage
**What could break**: Debug logs may contain:
- LLM prompts with full codebase context
- API keys in environment variables
- GitHub tokens in requests
- User comments/issue content

**Mitigation**:
- Filter environment variables: exclude GITHUB_TOKEN, ANTHROPIC_API_KEY
- Sanitize Claude requests/responses (mask API keys, tokens)
- Document privacy implications in help text
- Respect NO_GITHUB flag (don't log GitHub interactions)

**Implementation**:
```bash
debug_log_safe() {
    local msg="$1"
    # Filter known secrets
    msg="${msg//GITHUB_TOKEN=*/GITHUB_TOKEN=***}"
    msg="${msg//ANTHROPIC_API_KEY=*/ANTHROPIC_API_KEY=***}"
    echo "[$(date +%s.%N)] $msg" >> "$DEBUG_TRACE_LOG"
}
```

---

### High Risk: Test Suite Coverage Gaps
**What could break**: New tests may not catch:
- Debug mode interaction with worktree mode (`--worktree --debug`)
- Concurrency issues if multiple pipelines run with --debug simultaneously
- Debug mode with --dry-run flag

**Mitigation**:
- Test --debug with --worktree, --dry-run combinations
- Test concurrent pipelines writing to same debug/ dir (should use separate subdirs)
- Add tests for each decision point being logged

---

### Medium Risk: Performance Regression
**What could break**: Instrumenting every stage start/end could add latency:
- File I/O for every debug_log call
- JSON serialization of artifacts for snapshots

**Mitigation**:
- Batch debug_log calls where possible
- Use async writes (append to buffer, flush at stage boundaries)
- Profile with --debug on a 10-stage pipeline, verify <5% overhead

---

## Component Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ sw-pipeline.sh (main orchestrator)                              │
│ • parse_args --debug                                            │
│ • pipeline_start                                                │
└────────────────────────┬────────────────────────────────────────┘
                         │ sources
                    ┌────▼────────────────────────────┐
                    │ lib/pipeline-cli.sh              │
                    │ • parse_args() adds --debug case │
                    └────┬───────────────────────────┬─┘
                         │                           │
                    ┌────▼─────────────┐    ┌────────▼──────────┐
              ┌─────┤ lib/pipeline-    │    │ lib/pipeline-     │
              │     │ debug.sh (NEW)   │    │ execution.sh      │
              │     ├─────────────────┤    ├───────────────────┤
              │     │ • debug_log()   │    │ • run_stage_      │
              │     │ • debug_snapshot│    │   with_retry()    │
              │     │ • debug_event() │    │ • stage_*()       │
              │     └─────────────────┘    └────┬──────────────┘
              │              ▲                   │
              │              └───────────────────┘
              │                  calls debug_*() functions
              │
         ┌────▼──────────────────────────────────────────────┐
         │ lib/pipeline-stages-*.sh (intake, build, review)  │
         │ • Emit debug_event() on key decisions             │
         └────┬───────────────────────────────────────────────┘
              │
         ┌────▼──────────────────────────────────────────────┐
         │ .claude/pipeline-artifacts/debug/ (output)        │
         │ ├── debug-trace.log (microsecond timestamps)      │
         │ ├── plan.md.debug (snapshot before stage end)     │
         │ ├── design.md.debug (snapshot)                    │
         │ ├── test-results.log.debug (on failure)           │
         │ └── claude-output-XXX.log (full Claude output)    │
         └────────────────────────────────────────────────────┘
```

---

## Interface Contracts

### lib/pipeline-debug.sh (NEW MODULE)

```bash
# Initialize debug mode
# Inputs: (none - reads $DEBUG_ENABLED, $DEBUG_DIR, $ARTIFACTS_DIR)
# Outputs: Creates $DEBUG_TRACE_LOG, $DEBUG_DIR
# Returns: 0 always
pipeline_debug_init()

# Log a debug message with microsecond timestamp
# Signature: debug_log <level> <component> <message>
# Inputs: $1=level (INFO/WARN/ERROR/DECISION), $2=component, $3=message
# Outputs: Appends to $DEBUG_TRACE_LOG in format: timestamp|level|component|message
# Returns: 0 always
# Note: Filters secrets (GITHUB_TOKEN, ANTHROPIC_API_KEY)
debug_log()

# Snapshot an artifact file for debug analysis
# Signature: debug_snapshot <file_path> <label>
# Inputs: $1=source file path, $2=label (plan, design, test-results, etc)
# Outputs: Copies file to debug/${label}.debug with timestamp
# Returns: 0 on success, 1 if source doesn't exist
debug_snapshot()

# Log a decision point (template selection, model routing, timeout calculation)
# Signature: debug_event <decision_type> <key=value> [key=value...]
# Inputs: $1=type (template_selected, timeout_calculated, model_routed, retry_decided)
#         $@=key=value pairs (template=standard, reason="5 labels")
# Outputs: Appends to $DEBUG_TRACE_LOG and decision-events.json
# Returns: 0 always
debug_event()

# Start capturing Claude tool output
# Signature: debug_claude_output_start <stage_id>
# Inputs: $1=stage ID
# Outputs: Redirects fd 3 to debug/claude-output-${stage_id}.log
# Returns: 0 always
debug_claude_output_start()

# Stop capturing Claude output
# Signature: debug_claude_output_stop
# Inputs: (none)
# Outputs: Closes fd 3
# Returns: 0 always
debug_claude_output_stop()
```

### Modifications to lib/pipeline-execution.sh

```bash
# In run_stage_with_retry, before attempting stage:
if [[ "$DEBUG_ENABLED" == true ]]; then
    debug_log "INFO" "pipeline-execution" "Stage $stage_id starting (attempt $attempt)"
    debug_event "stage_started" stage="$stage_id" max_retries="$max_retries" attempt="$attempt"
    debug_claude_output_start "$stage_id"
fi

# In run_stage_with_retry, after stage success:
if [[ "$DEBUG_ENABLED" == true ]]; then
    debug_log "INFO" "pipeline-execution" "Stage $stage_id completed"
    debug_claude_output_stop
    debug_snapshot "${ARTIFACTS_DIR}/${stage_id}.md" "${stage_id}-result"
fi

# In run_stage_with_retry, on stage failure:
if [[ "$DEBUG_ENABLED" == true ]]; then
    debug_log "ERROR" "pipeline-execution" "Stage $stage_id failed"
    debug_event "stage_failed" stage="$stage_id" error_class="$error_class"
    debug_snapshot "${ARTIFACTS_DIR}/error-log.jsonl" "error-log"
    debug_claude_output_stop
fi
```

### Modifications to lib/pipeline-cli.sh (load_pipeline_config)

```bash
if [[ "$DEBUG_ENABLED" == true ]]; then
    debug_log "DECISION" "pipeline-cli" "Template selection: $PIPELINE_CONFIG"
    debug_event "template_selected" \
        template="$PIPELINE_NAME" \
        path="$PIPELINE_CONFIG" \
        source="$(basename $PIPELINE_CONFIG)" \
        issue_labels="${ISSUE_LABELS:-none}"
fi
```

---

## Data Flow

```
CLI Input
  │
  ├─ [parse_args --debug]
  │
  ├─ [pipeline_debug_init]
  │   └─ Creates: .claude/pipeline-artifacts/debug/
  │       • debug-trace.log (header + timestamps)
  │       • decision-events.json (empty array, appended to)
  │
  ├─ [load_pipeline_config]
  │   └─ [debug_event "template_selected" ...]
  │       └─ Appends to debug-trace.log
  │           Appends to decision-events.json
  │
  ├─ [for each stage]
  │   ├─ [run_stage_with_retry]
  │   │   ├─ [debug_log "INFO" ...]
  │   │   ├─ [debug_claude_output_start]
  │   │   │   └─ Creates: debug/claude-output-${stage_id}.log
  │   │   │       Captures: fd 3 to file
  │   │   ├─ [stage_intake/build/review/...]
  │   │   │   ├─ Calls to claude CLI → teed to fd 3
  │   │   │   └─ Calls to debug_event("retry_decided", ...)
  │   │   ├─ [debug_snapshot plan.md] (if stage completed)
  │   │   │   └─ Creates: debug/plan-result.debug
  │   │   └─ [debug_claude_output_stop]
  │   │
  │   └─ On stage failure:
  │       └─ [debug_snapshot error-log.jsonl]
  │
  └─ [pipeline end]
      └─ Creates: debug summary artifact with timeline
```

---

## Error Boundaries

### Boundary 1: Debug Module Initialization
**Component**: `pipeline_debug_init()`
**Error cases**:
- `$DEBUG_DIR` is not writable → log warning, continue without debug
- Cannot create .claude/pipeline-artifacts/debug/ → fallback to stderr logging

**Handler**: Non-fatal; pipeline continues. Error is logged to stderr.

```bash
if ! mkdir -p "$DEBUG_DIR" 2>/dev/null; then
    warn "Could not create debug dir: $DEBUG_DIR"
    return 1  # Non-fatal
fi
```

---

### Boundary 2: Artifact Snapshot
**Component**: `debug_snapshot()`
**Error cases**:
- Source file doesn't exist → skip silently (debug info is optional)
- Destination write fails (disk full) → log warning, continue

**Handler**: Graceful degradation; missing snapshots don't fail pipeline.

```bash
if [[ ! -f "$source_file" ]]; then
    return 1  # Silently continue
fi
if ! cp "$source_file" "$dest_file" 2>/dev/null; then
    debug_log "WARN" "pipeline-debug" "Failed to snapshot: $source_file"
fi
```

---

### Boundary 3: Claude Output Capture
**Component**: `debug_claude_output_start/stop()`
**Error cases**:
- File descriptor already in use → use next available fd (4, 5, ...)
- File I/O error during tee → fallback to direct redirection (no tee)

**Handler**: Attempt workarounds; if all fail, continue without output capture.

```bash
debug_claude_output_start() {
    local stage_id="$1"
    local output_file="$DEBUG_DIR/claude-output-${stage_id}.log"
    # Try fd 3, then 4, 5, 6 until one works
    for fd in 3 4 5 6; do
        if eval "exec ${fd}> >(tee -a '$output_file')" 2>/dev/null; then
            export DEBUG_CLAUDE_FD="$fd"
            return 0
        fi
    done
    # Fallback: direct redirection (no tee)
    exec 3> "$output_file" && return 0 || return 1
}
```

---

## Definition of Done

### Code Changes Complete ✅
- [ ] `lib/pipeline-debug.sh` created with all required functions
- [ ] `lib/pipeline-cli.sh` modified: --debug case added, help text updated
- [ ] `lib/pipeline-execution.sh` modified: debug calls at stage start/end/error
- [ ] `lib/pipeline-stages-intake.sh` modified: debug_event calls for key decisions
- [ ] Version bumped in sw-pipeline.sh (3.2.4 → 3.2.5)

### Testing Complete ✅
- [ ] `sw-pipeline-debug-test.sh` created with 20+ test cases
- [ ] Tests validate: --debug flag parsing, debug-trace.log format, artifact snapshots
- [ ] Tests validate: Claude output capture, decision events, performance <5% overhead
- [ ] E2E test: full pipeline with --debug produces all expected artifacts
- [ ] Tests pass: `npm test -- sw-pipeline-debug-test.sh`
- [ ] Regression tests pass: existing pipeline tests still pass

### Documentation Complete ✅
- [ ] Help text updated: `--debug` option documented with examples
- [ ] CLAUDE.md updated: new `--debug` flag documented with use cases
- [ ] README section added: "Debugging Failed Pipelines" with examples
- [ ] Debug output schema documented (debug-trace.log format)
- [ ] Privacy implications documented (sanitization of secrets)

### Artifacts Verified ✅
- [ ] Debug artifacts are created in correct location: `.claude/pipeline-artifacts/debug/`
- [ ] File permissions are correct (readable by user)
- [ ] No sensitive information leaks (secrets filtered)
- [ ] All decision points logged (template, timeout, model, retry)
- [ ] Timestamps are microsecond precision: `date +%s.%N`

### Performance Verified ✅
- [ ] Benchmark: pipeline runtime with --debug vs without
- [ ] Overhead < 5% confirmed
- [ ] No memory leaks (file descriptors properly closed)
- [ ] Large pipelines (20+ stages) don't consume excessive disk

---

## Alternatives Considered

### Alternative: Use `set -x` Debug Shell Mode
**Approach**: Enable Bash debug mode with `PS4='[$(date +%s.%N)] ...'`

**Trade-offs**:
- ✅ Zero code changes needed
- ✅ Captures everything (function calls, variable assignments)
- ❌ Extremely verbose output (100MB+ logs for single pipeline run)
- ❌ Difficult to parse and analyze
- ❌ Interferes with tests (output noise)

**Why rejected**: Too much noise, makes it harder to diagnose the actual issue. Our structured approach is 100x more useful.

---

### Alternative: Integration with Existing emit_event System
**Approach**: Extend emit_event to write to debug-trace.log when DEBUG_ENABLED=true

**Trade-offs**:
- ✅ Leverages existing infrastructure
- ✅ No new module needed
- ❌ Can't capture intermediate state (artifacts)
- ❌ Can't capture full Claude output
- ❌ emit_event system is event-centric, not state-centric

**Why rejected**: Insufficient fidelity. emit_event fires at discrete moments; we need continuous state capture.

---

## Failure Mode Analysis

### Failure Mode 1: File Descriptor Exhaustion in Long Pipelines
**Scenario**: 20-stage pipeline with --debug, each stage opens fd 3 for Claude output capture.

**Impact**: File descriptor limit (typically 1024) could be exceeded if descriptors not properly closed.

**Probability**: Medium (only affects very long pipelines)

**Mitigation**:
- Explicitly close file descriptors in debug_claude_output_stop()
- Use trap to ensure cleanup on early exit
- Test with 50+ stages to verify no fd leaks

**Implementation**:
```bash
debug_claude_output_stop() {
    [[ -n "${DEBUG_CLAUDE_FD:-}" ]] && eval "exec ${DEBUG_CLAUDE_FD}>&-"
    unset DEBUG_CLAUDE_FD
}
trap 'debug_claude_output_stop' EXIT  # In pipeline_debug_init
```

---

### Failure Mode 2: Concurrent Debug Writes (Worktree Mode)
**Scenario**: User runs `shipwright pipeline start --issue 42 --debug --worktree` and `--issue 43 --debug --worktree` simultaneously.

**Impact**: Two pipelines write to same `.claude/pipeline-artifacts/debug/` directory, logs interleave unpredictably.

**Probability**: Medium (worktree mode encourages parallelism)

**Mitigation**:
- Create per-pipeline debug subdirectory: `debug/pipeline-${PIPELINE_AGENT_ID}/`
- Each pipeline writes to isolated directory
- Helper function to find all debug directories: `find .claude/pipeline-artifacts/debug -type d -name 'pipeline-*'`

**Implementation**:
```bash
pipeline_debug_init() {
    DEBUG_AGENT_DIR="$DEBUG_DIR/pipeline-${PIPELINE_AGENT_ID:-$$}"
    mkdir -p "$DEBUG_AGENT_DIR"
    # Use per-pipeline directory
}
```

---

### Failure Mode 3: Disk Space Exhaustion
**Scenario**: User runs 100 pipelines with --debug over a week; debug artifacts consume 10GB.

**Impact**: Disk full, pipeline fails with obscure "No space left on device" error.

**Probability**: High (debug artifacts can be large)

**Mitigation**:
- Rotate debug logs at 100MB per pipeline
- Add --debug-retention <days> flag (default 30 days)
- Warn user if debug dir > 1GB
- Document retention policy in help text

**Implementation**:
```bash
pipeline_debug_cleanup() {
    local retention_days="${DEBUG_RETENTION:-30}"
    find "$DEBUG_DIR" -type f -mtime "+$retention_days" -delete

    local total_size=$(du -sh "$DEBUG_DIR" 2>/dev/null | cut -f1)
    if [[ $(du -s "$DEBUG_DIR" | cut -f1) -gt $((1024*1024*1024)) ]]; then
        warn "Debug artifacts directory > 1GB: $total_size"
    fi
}
```

---

### Failure Mode 4: Secrets Leakage in Debug Logs
**Scenario**: Debug log captures full Claude API request with system prompt containing codebase context; log is accidentally shared publicly (GitHub issue, Slack, etc).

**Impact**: LLM prompt injection attacks, code leakage, token compromise.

**Probability**: Medium (users may carelessly share debug logs)

**Mitigation**:
- Sanitize known secrets in debug_log_safe(): API keys, GitHub tokens
- Document that debug logs may contain sensitive information
- Never log full LLM system prompts; log only prompt hash
- Add sanitization rules for common patterns (AWS keys, private URLs)

**Implementation**:
```bash
debug_log_safe() {
    local msg="$1"
    # Filter secrets
    msg="${msg//GITHUB_TOKEN=*/GITHUB_TOKEN=***}"
    msg="${msg//ANTHROPIC_API_KEY=*/ANTHROPIC_API_KEY=***}"
    msg="${msg//Bearer [A-Za-z0-9_-]*/Bearer ***}"  # JWT tokens
    msg="${msg//api_key=[A-Za-z0-9_-]*/api_key=***}"
    echo "[$(date +%s.%N)] $msg" >> "$DEBUG_TRACE_LOG"
}
```

---

### Failure Mode 5: Debug Mode Changes Pipeline Behavior
**Scenario**: Pipeline with --debug behaves differently than without (e.g., stage succeeds with debug but fails without).

**Impact**: Makes debugging misleading; user thinks they've fixed the issue but haven't.

**Probability**: Low (instrumentation shouldn't change behavior)

**Mitigation**:
- Ensure debug_log calls are side-effect-free (read-only)
- No conditional logic based on DEBUG_ENABLED in stage functions
- Test all stages with and without --debug; compare results
- Add regression test that runs same pipeline 5 times with/without --debug, verifies identical outcomes

---

## Task Checklist

### Phase 1: Infrastructure Setup
- [ ] **Task 1.1**: Create lib/pipeline-debug.sh with:
  - [ ] pipeline_debug_init() function
  - [ ] debug_log() function with secret filtering
  - [ ] debug_snapshot() function
  - [ ] debug_event() function
  - [ ] debug_claude_output_start/stop() functions
  - [ ] Global variables: DEBUG_ENABLED, DEBUG_DIR, DEBUG_TRACE_LOG
  - [ ] Module guard ([[ -n "${_MODULE_PIPELINE_DEBUG_LOADED:-}" ]])

- [ ] **Task 1.2**: Source lib/pipeline-debug.sh from sw-pipeline.sh (after helpers.sh, before parse_args)

- [ ] **Task 1.3**: Add --debug argument to lib/pipeline-cli.sh:
  - [ ] Case statement: `--debug) DEBUG_ENABLED=true; shift ;;`
  - [ ] Export DEBUG_ENABLED variable
  - [ ] Add help text: `--debug                  Enable verbose pipeline instrumentation`
  - [ ] Add example: `shipwright pipeline start --issue 123 --debug`

### Phase 2: Stage Instrumentation
- [ ] **Task 2.1**: Modify lib/pipeline-execution.sh run_stage_with_retry():
  - [ ] Add debug_log() at stage start
  - [ ] Add debug_log() at stage success
  - [ ] Add debug_log() at stage failure
  - [ ] Add debug_event() for retry decisions

- [ ] **Task 2.2**: Add debug_event calls to decision points:
  - [ ] lib/pipeline-cli.sh load_pipeline_config(): template selection
  - [ ] lib/adaptive-timeout.sh (if present): timeout calculation
  - [ ] lib/pipeline-intelligence.sh (if present): model routing
  - [ ] lib/pipeline-execution.sh: retry decisions

- [ ] **Task 2.3**: Artifact snapshots:
  - [ ] Call debug_snapshot() for plan.md after intake/plan stages
  - [ ] Call debug_snapshot() for design.md after design stage
  - [ ] Call debug_snapshot() for test-results.log on test failures
  - [ ] Call debug_snapshot() for error-log.jsonl on stage failure

### Phase 3: Claude Output Preservation
- [ ] **Task 3.1**: Capture Claude tool output:
  - [ ] Modify stage implementations to call debug_claude_output_start before claude CLI invocation
  - [ ] Wrap claude CLI calls with output redirection: `claude ... 2>&3`
  - [ ] Call debug_claude_output_stop after stage completes

- [ ] **Task 3.2**: Handle tool output errors:
  - [ ] If output capture fails, continue without it (non-fatal)
  - [ ] Log warning if tee fails: "Failed to capture Claude output"

### Phase 4: Documentation & Testing
- [ ] **Task 4.1**: Create sw-pipeline-debug-test.sh:
  - [ ] Test --debug flag parsing (verify DEBUG_ENABLED set)
  - [ ] Test debug-trace.log creation and format
  - [ ] Test debug directory structure
  - [ ] Test debug_log() timestamp format (microseconds)
  - [ ] Test debug_snapshot() creates files
  - [ ] Test debug_event() appends to decision-events.json
  - [ ] Test artifact snapshots for all stage types
  - [ ] Test concurrent debug writes (worktree scenario)
  - [ ] Test secret filtering in logs
  - [ ] Test performance overhead < 5%

- [ ] **Task 4.2**: Update help text:
  - [ ] Add --debug to START OPTIONS in show_help()
  - [ ] Add example usage
  - [ ] Document output location (.claude/pipeline-artifacts/debug/)
  - [ ] Note about performance/disk usage

- [ ] **Task 4.3**: Update CLAUDE.md:
  - [ ] Add "Debug Mode" section
  - [ ] Document --debug flag and use cases
  - [ ] Document debug output format (debug-trace.log schema)
  - [ ] Document privacy implications (secret filtering)
  - [ ] Link to examples

- [ ] **Task 4.4**: Integration tests:
  - [ ] Full pipeline with --debug (happy path)
  - [ ] Full pipeline with --debug (failure path)
  - [ ] Verify all expected artifacts exist
  - [ ] Verify no performance regression

### Phase 5: Polish & Validation
- [ ] **Task 5.1**: Version bump:
  - [ ] Update VERSION in sw-pipeline.sh: 3.2.4 → 3.2.5
  - [ ] Verify version consistency: `shipwright version check`

- [ ] **Task 5.2**: Code quality:
  - [ ] shellcheck lib/pipeline-debug.sh
  - [ ] shellcheck modified files (cli.sh, execution.sh, stages-*.sh)
  - [ ] No new warnings introduced

- [ ] **Task 5.3**: Performance validation:
  - [ ] Run 10 pipelines with --debug, measure runtime
  - [ ] Compare vs 10 pipelines without --debug
  - [ ] Verify overhead < 5%
  - [ ] Verify no file descriptor leaks (lsof)

- [ ] **Task 5.4**: Final validation:
  - [ ] All tests pass: `npm test -- sw-pipeline-debug-test.sh`
  - [ ] Regression tests pass: existing pipeline tests still pass
  - [ ] Manual test: run pipeline with --debug, inspect artifacts
  - [ ] Documentation complete and reviewed

---

## Testing Approach

### Test Pyramid for Debug Mode
- **Unit Tests (80)**: Individual functions (debug_log, debug_snapshot, debug_event)
- **Integration Tests (15)**: Stage instrumentation with mock stages
- **E2E Tests (5)**: Full pipeline with --debug flag

### Critical Paths to Test
1. **Happy Path**: Full pipeline with --debug completes successfully
   - All debug artifacts created
   - Timestamps accurate
   - No performance regression

2. **Failure Path**: Pipeline fails at stage 3, debug logs captured
   - Error logged with error_class and error snippet
   - Artifact snapshots of failed stage
   - Claude output capture includes error messages

3. **Decision Points**:
   - Template selection logged with reason
   - Retry decision logged with attempt count
   - Model routing logged with model selection

4. **Edge Cases**:
   - --debug with --dry-run (no artifacts created, just logs)
   - --debug with --worktree (isolated debug directories)
   - --debug with concurrent pipelines (no log interleaving)
   - Disk full scenario (graceful degradation)
   - Large pipelines (20+ stages, verify fd not exhausted)

---

## Implementation Notes

### Code Style & Standards
- Follow existing bash style: `set -euo pipefail`, shellcheck clean
- Use existing helpers: `info()`, `warn()`, `error()`, `emit_event()`
- Preserve atomic file writes (tmp + mv, not direct echo)
- No bashisms: Bash 3.2 compatible

### Performance Targets
- Debug init overhead: < 10ms
- Per-stage debug logging overhead: < 100ms (avoid sync disk writes)
- Overall pipeline overhead with --debug: < 5% (preferably < 2%)

### Security Considerations
- Sanitize secrets in all debug output (API keys, tokens, passwords)
- Respect NO_GITHUB flag (don't log GitHub API interactions)
- Debug logs may be sensitive; document privacy implications
- Consider adding --debug-no-output flag to skip Claude output capture (trust-but-verify)

---

## Success Metrics

**User Story**: "As a developer, I can run `shipwright pipeline start --issue 123 --debug` and get a complete audit trail of why the pipeline failed, including timestamps, decision points, and intermediate artifacts."

**Acceptance Criteria**:
1. ✅ Debug flag exists and is documented
2. ✅ Debug artifacts are created in consistent location
3. ✅ Timestamps are microsecond precision
4. ✅ All decision points (template, model, retry) are logged
5. ✅ Full Claude output is captured
6. ✅ Performance overhead < 5%
7. ✅ Test suite validates all above criteria
8. ✅ Documentation includes examples

