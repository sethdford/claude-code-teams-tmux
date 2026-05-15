# ADR: Pipeline Git State Validator and Auto-Cleanup Between Stages

**Status**: PROPOSED  
**Decision Date**: 2026-05-15  
**Authors**: Shipwright Design Team  
**Issue**: #478

---

## 1. Context

### Problem Statement

Pipeline stages produce artifacts (build outputs, test results, coverage, review documents) that accumulate in the working tree. If a stage fails or is interrupted, subsequent stages may operate on dirty state—untracked files, uncommitted changes, or branch mismatches—leading to:

- Silent failures (e.g., test stage runs against stale build artifacts)
- Cascading errors (e.g., PR stage attempts to push from wrong branch)
- Difficult diagnostics (which stage left this `.env` file?)
- Parallel pipeline conflicts (two worktrees touch the same untracked file)

**Scope**: This ADR designs the before/after git-state validation hooks that wrap all 14 pipeline stages (`intake` through `monitor`), catching dirty state early with clear recovery paths.

### Constraints

1. **Bash 3.2 compatibility** — No `declare -A`, `readarray`, `${var,,}` or other bash 4+ features
2. **Minimal blast radius** — No breaking changes to existing pipelines on first PR; safe defaults
3. **Worktree-aware** — Each worktree has isolated working state; validation must be per-worktree
4. **Interactive-safe** — Auto-stash only in daemon/CI; interactive sessions get abort + recovery hint
5. **Observability** — All decisions emit structured events for metrics, debugging, and auditing
6. **No git hook footprint** — Can't rely on `.git/hooks/` because worktrees and local-mode skips don't support them

### Existing Infrastructure

- **Pipeline dispatcher** (`scripts/lib/pipeline-execution.sh::run_stage_with_retry`) — Wraps each stage call with retry logic and error classification
- **Event system** (`emit_event`) — Structured logging to `.shipwright/events.jsonl`
- **Error classification** (`classify_error`) — Short-circuits retries for certain error classes (e.g., `configuration`)
- **Stage functions** (`stage_intake`, `stage_plan`, ..., `stage_monitor`) — Individual stage implementations in `scripts/lib/pipeline-stages.sh`
- **Atomic writes** (`scripts/lib/compat.sh`) — Safe file updates via `tmp` + `mv`

---

## 2. Decision

### Chosen Approach: **Decorator Pattern in Dispatcher**

Wrap the stage function call in the dispatcher with before/after validation checks. The validator consults a declarative **stage manifest** (`stage-manifests.json`) to decide policy per stage.

**Key Design Decisions**:

| Decision                    | Rationale                                                                                                                                               | Alternative Rejected                                                                                   |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| **Manifest-driven policy**  | Each stage declares its own expected outputs and before/after behavior (abort/auto-stash/warn). One source of truth, evolvable independently per stage. | Hard-coded switch statements in validator lib; scales poorly as stages evolve.                         |
| **Decorator in dispatcher** | One change site (`run_stage_with_retry`), uniform coverage of all 14 stages, easy rollback.                                                             | Manual hook calls in each stage function; 14 edit sites, higher risk of missing one.                   |
| **No git hooks**            | Stage functions already read/write state outside `.git/hooks` scope (e.g., `.claude/pipeline-artifacts/`). Native hooks don't fire in local-mode.       | Use `.git/hooks/pre-commit` or `post-checkout`; doesn't cover non-commit stages, fragile in worktrees. |
| **Atomic stash log**        | Record all stashes in `.claude/pipeline-artifacts/git-validator-stashes.jsonl` (tmp + `mv`) so parallel pipelines don't collide.                        | Single shared lock file; slow under contention.                                                        |
| **Error class escalation**  | Introduce new `git_state_dirty` error class so dispatcher's retry loop skips retries on dirty-state abort (mirrors existing `configuration` class).     | Merge into existing error classes; loses specificity, harder to debug.                                 |

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│ Pipeline Execution (scripts/lib/pipeline-execution.sh)       │
│                                                              │
│  run_stage_with_retry(stage_id):                            │
│    1. pre_sha = git rev-parse HEAD                          │
│    2. validate_before_stage($stage_id) ← NEW                │
│       └─ Read manifest, check forbidden_paths, apply policy │
│    3. stage_${stage_id}() [original stage function]         │
│    4. validate_after_stage($stage_id, $pre_sha) ← NEW       │
│       └─ Diff HEAD..$pre_sha, check against expected_paths  │
│    5. Emit "git_state.ok|warn|fail" event                   │
└─────────────────────────────────────────────────────────────┘
         │
         ├─→ scripts/lib/git-state-validator.sh ← NEW
         │     ├─ validate_before_stage()
         │     ├─ validate_after_stage()
         │     ├─ _load_stage_manifest()
         │     ├─ _auto_stash_dirty()
         │     └─ _classify_dirty_entries()
         │
         └─→ .claude/pipeline-artifacts/stage-manifests.json ← NEW
               ├─ expected_paths[]: glob list of files that SHOULD change
               ├─ forbidden_paths[]: glob list of files that MUST NOT change
               ├─ before_policy: "abort" | "auto_stash" | "warn"
               └─ after_policy: "abort" | "warn"
```

### Component Responsibilities

| Component             | Responsibility                                                                                               | Boundary                                                                     |
| --------------------- | ------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| **Dispatcher**        | Owns when validation runs (before/after stage call); owns error classification and retry semantics           | Only calls validator functions; doesn't read manifest                        |
| **Validator Library** | Owns HOW to detect dirty state (git status, diff, glob matching); owns policy application (stash/abort/warn) | Only returns success/failure and emits events; doesn't modify dispatch logic |
| **Stage Manifest**    | Declares WHAT each stage expects/forbids                                                                     | JSON schema-validated; updated via PR with sign-off                          |
| **Stash Log**         | Audit trail of auto-stashed work (who, when, which stage)                                                    | Append-only; cleaned up by separate `sw-cleanup --gc` command (not this ADR) |

---

## 3. Alternatives Considered

### Alternative 1: Decorator in Dispatcher (✓ CHOSEN)

**Approach**: Wrap the `stage_${stage_id}` call in `run_stage_with_retry` with validation before/after.

**Pros**:

- Single change site — minimal risk, easy code review
- Uniform coverage — all 14 stages automatically validated
- Manifest is source-of-truth — policies evolve independently from code
- Easy rollback — delete 25 lines from dispatcher, remove manifest file
- Integrates naturally with existing retry/error-class logic

**Cons**:

- Manifest can drift from stage implementation (e.g., build stage starts writing to `artifacts/` but manifest only lists `src/**/*.js`)
- All stages validated even if they don't need it (mitigation: per-stage policy can be `warn`)
- One more `git` call per stage (perf: ~30ms on this repo, negligible)

**Risk Level**: 🟢 LOW — All logic is new (no existing code modified except dispatcher wrapper)

---

### Alternative 2: Manual Hook Calls in Each Stage Function

**Approach**: Edit all 14 stage functions in `scripts/lib/pipeline-stages.sh` to call `validate_before_stage` and `validate_after_stage` at the start/end of each function.

**Pros**:

- Stages declare their own contract inline — easier to understand locally
- Validation can be more tightly scoped to stage-specific logic
- No single integration point — failures don't affect all stages

**Cons**:

- 14 edit sites = 14× chance to forget one or typo the call
- **Verification burden**: AC #5 requires grep-based test to prove all 14 stages call validator — risk of false-pass if any stage is missed
- Higher review surface — each stage edit increases diff size and cognitive load
- Harder to evolve later (e.g., changing validator signature requires 14 updates)
- No way to enforce consistency; some stages might call before-only, others after-only

**Risk Level**: 🔴 HIGH — Distributed changes, high miss risk, violates AC #5

---

### Alternative 3: Native Git Hooks (`.git/hooks/pre-commit` or `post-checkout`)

**Approach**: Implement validation in native git hooks that fire automatically on `git status` and `git diff` events.

**Pros**:

- Zero pipeline integration — git itself enforces state invariants
- Works for all git operations, not just pipeline stages
- Git framework handles atomicity and error handling

**Cons**:

- **Doesn't fire in non-commit stages** — `plan`, `design`, `review` don't commit; validation would be skipped
- **Broken in worktrees** — Each worktree has its own working state but shares `.git/hooks`; can't isolate per-worktree policy
- **Broken in local-mode** — When `LOCAL_MODE=1`, users intentionally keep dirty state; git hooks would interfere
- **Not portable** — Requires writing hooks to `.git/hooks/`, fragile if user has their own hooks
- **Hard to mock for testing** — Test fixtures would need real git repos with hook setup
- **Doesn't support auto-stash** — Git hooks can't cleanly auto-stash and resume; would need separate cleanup logic anyway

**Risk Level**: 🔴 HIGH — Structural misalignment with pipeline stages and worktrees

---

## 4. Implementation Plan

### Files to Create

1. **`scripts/lib/git-state-validator.sh`** (~300 lines)
   - Public API: `validate_before_stage()`, `validate_after_stage()`
   - Helpers: `_load_stage_manifest()`, `_classify_dirty_entries()`, `_auto_stash_dirty()`, `_format_recovery_hint()`
   - Event emissions: `git_state.before_ok`, `git_state.before_warn`, `git_state.before_stashed`, `git_state.before_fail`, `git_state.after_ok`, `git_state.after_warn`, `git_state.after_fail`
   - Escape hatches: `SW_DISABLE_GIT_VALIDATOR=1` (disable all validation), `LOCAL_MODE=1` (downgrade abort→warn)

2. **`.claude/pipeline-artifacts/stage-manifests.json`** (~150 lines)
   - Schema: `{ stages: { <stage_id>: { expected_paths, forbidden_paths, before_policy, after_policy, description? } } }`
   - All 14 stages with reasonable defaults:
     - `intake`, `plan`, `design`, `spec_generation`: `before_policy=auto_stash`, `after_policy=warn`
     - `build`, `test`: `before_policy=auto_stash`, `after_policy=warn`
     - `review`, `spec_verification`, `compound_quality`: `before_policy=abort`, `after_policy=abort`
     - `pr`, `merge`: `before_policy=abort`, `after_policy=abort` (no local edits allowed before PR)
     - `deploy`, `validate`, `monitor`: `before_policy=warn`, `after_policy=warn`

3. **`scripts/sw-git-state-validator-test.sh`** (~350 lines)
   - Unit tests: manifest parsing, glob matching, policy application, escape hatches
   - Integration test: mock `run_stage_with_retry` call with injected dirty state
   - Test fixtures: `git init` repos, untracked files, uncommitted changes
   - Coverage: all error classes, all policies, LOCAL_MODE branch, disabled validator

### Files to Modify

1. **`scripts/lib/pipeline-execution.sh`** (~25 lines)
   - Line ~39: Add `source "${SCRIPT_DIR}/lib/git-state-validator.sh"` (after existing source statements)
   - In `run_stage_with_retry()` function (line ~60-70 range):

     ```bash
     local _pre_stage_sha
     _pre_stage_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

     # NEW: Before-stage validation
     if ! validate_before_stage "$stage_id"; then
         LAST_STAGE_ERROR_CLASS="git_state_dirty"
         return 1
     fi

     # Existing stage call
     if "stage_${stage_id}"; then
         # NEW: After-stage validation (non-fatal — logs warn/fail but doesn't abort)
         validate_after_stage "$stage_id" "$_pre_stage_sha" || true
         return 0
     fi
     # existing error handling...
     ```

2. **`package.json`** (1 line)
   - Add `"scripts/sw-git-state-validator-test.sh"` to test fan-out in `"test"` script

3. **`.claude/CLAUDE.md`** (~20 lines)
   - Add row to "Shared Libraries" table: `| git-state-validator.sh | ~300 | Git-state validation hooks before/after each pipeline stage |`
   - Add subsection under "Pipeline Stages" describing manifest, policies, escape hatches, and how to evolve

### Dependencies

**New runtime dependencies**: None (uses only `jq`, `git`, bash builtins — all already present)

**New development dependencies**: None

**Integration points**:

- `scripts/lib/helpers.sh` — `emit_event()`, `info()`, `warn()`, `error()` (already sourced by pipeline-execution.sh)
- `scripts/lib/compat.sh` — Atomic writes via tmp + `mv` (already available)
- `git` CLI — `git status`, `git diff`, `git stash`, `git rev-parse` (already used throughout)

---

## 5. Validation Criteria

- [ ] **Manifest valid JSON**: `.claude/pipeline-artifacts/stage-manifests.json` parses with `jq` and contains all 14 stages
- [ ] **Validator library exists**: `scripts/lib/git-state-validator.sh` is sourced by `pipeline-execution.sh` and exports `validate_before_stage` and `validate_after_stage`
- [ ] **Before-validation works**: Calling `validate_before_stage "build"` with untracked forbidden files returns 1 and emits `git_state.before_fail` event
- [ ] **Auto-stash works**: With `SHIPWRIGHT_DAEMON=1`, untracked files are stashed, function returns 0, event is `git_state.before_stashed`
- [ ] **Recovery hint emitted**: On abort, stderr includes actionable `git stash` or `git checkout` command
- [ ] **After-validation works**: Calling `validate_after_stage "build" "$pre_sha"` flags unexpected files modified after the stage ran
- [ ] **All 14 stages called**: Integration test or grep confirms `validate_before_stage "$stage_id"` is called for each of the 14 stages
- [ ] **Dispatcher integration test**: Mock stage that writes a forbidden file; assert before-validation catches it
- [ ] **LOCAL_MODE downgrade**: With `LOCAL_MODE=1`, abort policies become warn; function returns 0 instead of 1
- [ ] **Escape hatch works**: With `SW_DISABLE_GIT_VALIDATOR=1`, both validate functions return 0 immediately (no-op)
- [ ] **Bash 3.2 compat**: `shellcheck -S warning` on validator.sh; no bash 4+ features used
- [ ] **No regressions**: Run `npm test` including full pipeline suite; all existing tests pass
- [ ] **Docs updated**: `shipwright docs check` reports no stale AUTO sections in `.claude/CLAUDE.md`

---

## 6. Component Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                      Pipeline Dispatcher                              │
│              (scripts/lib/pipeline-execution.sh)                       │
│                                                                        │
│  ┌─────────────────────────────────────────────────────────────┐      │
│  │ run_stage_with_retry(stage_id)                              │      │
│  │                                                              │      │
│  │  1. Capture git HEAD: pre_sha=$(git rev-parse HEAD)         │      │
│  │  2. ┌──────────────────────────────────────────────────┐    │      │
│  │     │ validate_before_stage($stage_id) ← NEW           │    │      │
│  │     │   Returns: 0 (clean) | 1 (dirty/abort)           │    │      │
│  │     │   Side effects: auto-stash, emit event            │    │      │
│  │     └──────────────────────────────────────────────────┘    │      │
│  │  3. Execute stage_${stage_id}()                             │      │
│  │  4. ┌──────────────────────────────────────────────────┐    │      │
│  │     │ validate_after_stage($stage_id, $pre_sha) ← NEW  │    │      │
│  │     │   Returns: 0 (ok/warn) always (non-fatal)         │    │      │
│  │     │   Side effects: emit event                        │    │      │
│  │     └──────────────────────────────────────────────────┘    │      │
│  │  5. Return success/failure                                   │      │
│  │                                                              │      │
│  │  Error Classification:                                       │      │
│  │    - Before abort: LAST_STAGE_ERROR_CLASS="git_state_dirty" │      │
│  │      ↓ Short-circuits retry loop (like "configuration")    │      │
│  │    - After fail: Emits event, continues (non-fatal)        │      │
│  └─────────────────────────────────────────────────────────────┘      │
└──────────────────────────────────────────────────────────────────────┘
         │
         ├─────────────────────────────────────────────────┐
         │                                                 │
         ▼                                                 ▼
┌─────────────────────────────────┐     ┌──────────────────────────────┐
│ Validator Library (NEW)          │     │ Stage Manifest (NEW)         │
│ scripts/lib/                     │     │ .claude/pipeline-artifacts/  │
│ git-state-validator.sh           │     │ stage-manifests.json         │
│                                  │     │                              │
│ Public:                          │     │ {                            │
│  validate_before_stage()         │     │   "stages": {                │
│  validate_after_stage()          │     │     "build": {               │
│                                  │     │       "expected_paths": [    │
│ Private:                         │     │         "src/**/*.js"        │
│  _load_stage_manifest()          │     │       ],                     │
│  _classify_dirty_entries()       │     │       "forbidden_paths": [   │
│  _auto_stash_dirty()             │     │         "node_modules/**",   │
│  _format_recovery_hint()         │     │         ".env*",            │
│                                  │     │         ".git/**"           │
│ Events:                          │     │       ],                     │
│  git_state.before_{ok|warn|...}  │     │       "before_policy": "..." │
│  git_state.after_{ok|warn|...}   │     │       "after_policy": "..."  │
│                                  │     │     }                        │
│                                  │     │   }                          │
│                                  │     │ }                            │
└─────────────────────────────────┘     └──────────────────────────────┘
         │
         │ reads/writes
         ▼
┌─────────────────────────────────────────────────────────┐
│ Git State & Artifacts                                   │
│                                                         │
│ git status --porcelain ───→ detect dirty files          │
│ git diff HEAD~1..HEAD ───→ check file changes vs. pre   │
│ git stash push -u ───→ auto-stash untracked files       │
│                                                         │
│ .claude/pipeline-artifacts/                            │
│   └─ git-validator-stashes.jsonl ← Stash audit log     │
└─────────────────────────────────────────────────────────┘
```

---

## 7. Interface Contracts

### Primary Functions

```bash
# Before-stage validation: Check for uncommitted/untracked files
# Returns: 0 if clean or action taken; 1 if abort requested
# Exit codes:
#   0 = validation passed (clean or auto-stashed)
#   1 = validation failed (abort, recovery hint emitted to stderr)
validate_before_stage() {
  # Input:
  #   $1: stage_id (string: "build", "test", "pr", etc.)
  # Output:
  #   stdout: empty or diagnostic (usually none)
  #   stderr: recovery hint if abort (e.g., "git stash" command)
  # Side effects:
  #   - Reads .claude/pipeline-artifacts/stage-manifests.json
  #   - May call git status --porcelain
  #   - May call git stash push (if before_policy=auto_stash)
  #   - Emits event: "git_state.before_ok" | "git_state.before_warn" | "git_state.before_stashed" | "git_state.before_fail"
  # Environment:
  #   SW_DISABLE_GIT_VALIDATOR: If "1", return 0 immediately (no-op)
  #   LOCAL_MODE: If "1", downgrade abort → warn (return 0, emit warning)
  #   SHIPWRIGHT_DAEMON: If "1", enable auto_stash; else abort on dirty
  #   CI: If "true", enable auto_stash (same as SHIPWRIGHT_DAEMON)
}

# After-stage validation: Check actual file changes vs. manifest
# Returns: 0 if ok/warn; 1 if abort requested (but we use || true in dispatcher)
# Exit codes:
#   0 = validation passed (changes match manifest)
#   1 = validation failed (abort policy requested, but caller must use || true)
validate_after_stage() {
  # Input:
  #   $1: stage_id (string: "build", "test", etc.)
  #   $2: pre_stage_sha (git SHA before stage ran, e.g., from git rev-parse HEAD)
  # Output:
  #   stdout: empty
  #   stderr: diagnostic summary if warn/fail
  # Side effects:
  #   - Reads .claude/pipeline-artifacts/stage-manifests.json
  #   - Calls git diff --name-only $pre_sha..HEAD
  #   - Emits event: "git_state.after_ok" | "git_state.after_warn" | "git_state.after_fail"
  # Environment:
  #   SW_DISABLE_GIT_VALIDATOR: If "1", return 0 immediately (no-op)
  #   LOCAL_MODE: If "1", downgrade abort → warn
}
```

### Manifest Schema

```json
{
  "version": "1.0",
  "stages": {
    "<stage_id>": {
      "description": "Human-readable description (optional)",
      "expected_paths": [
        "<glob_pattern>",
        "..."
      ],
      "forbidden_paths": [
        "<glob_pattern>",
        "..."
      ],
      "before_policy": "abort" | "auto_stash" | "warn",
      "after_policy": "abort" | "warn"
    }
  }
}
```

**Example Entry** (build stage):

```json
{
  "build": {
    "description": "Compile TypeScript, bundle, output to dist/",
    "expected_paths": [
      "dist/**/*.js",
      "dist/**/*.map",
      ".claude/pipeline-artifacts/build.log"
    ],
    "forbidden_paths": ["node_modules/**", ".env*", "*.tmp", ".git/**"],
    "before_policy": "auto_stash",
    "after_policy": "warn"
  }
}
```

### Event Schema

```bash
# Before-stage events
emit_event "git_state.before_ok" \
  "stage=build" \
  "clean=true" \
  "files=0"

emit_event "git_state.before_warn" \
  "stage=build" \
  "dirty_files=1" \
  "reason=untracked .env.local"

emit_event "git_state.before_stashed" \
  "stage=build" \
  "dirty_files=2" \
  "stash_ref=shipwright:pre-build:1715761575:$$"

emit_event "git_state.before_fail" \
  "stage=pr" \
  "dirty_files=1" \
  "forbidden=src/index.js" \
  "reason=abort policy"

# After-stage events
emit_event "git_state.after_ok" \
  "stage=build" \
  "files_changed=3" \
  "all_expected=true"

emit_event "git_state.after_warn" \
  "stage=build" \
  "files_changed=4" \
  "unexpected=1" \
  "file=.DS_Store"

emit_event "git_state.after_fail" \
  "stage=pr" \
  "files_changed=2" \
  "forbidden_changes=1" \
  "file=src/dead-code.js"
```

### Stash Log Schema

`.claude/pipeline-artifacts/git-validator-stashes.jsonl` (append-only):

```json
{
  "timestamp": "2026-05-15T12:34:56Z",
  "stage_id": "build",
  "pre_sha": "abc123...",
  "stash_ref": "shipwright:pre-build:1715761575:12345",
  "dirty_files": ["src/foo.js", "package-lock.json"],
  "worktree": "/home/runner/work/shipwright/.claude/worktrees/test-branch",
  "pipeline_id": "issue-478"
}
```

---

## 8. Data Flow

### Happy Path: Clean Working Tree

```
Stage: Build
│
├─ Before validation
│  ├─ Load manifest for "build"
│  ├─ Run: git status --porcelain
│  │  Output: (empty — clean tree)
│  ├─ Compare against forbidden_paths
│  │  Result: No forbidden files found
│  └─ Emit: git_state.before_ok
│  └─ Return: 0 (success)
│
├─ [Stage executes normally]
│  ├─ npm run build
│  ├─ Outputs: dist/, .coverage, build.log
│
├─ After validation
│  ├─ Load manifest for "build"
│  ├─ Diff: git diff --name-only <pre_sha>..HEAD
│  │  Output: dist/index.js, dist/app.js, .coverage/statements.json
│  ├─ Check against expected_paths (dist/**, .coverage/**)
│  │  Result: All files expected
│  ├─ Check against forbidden_paths
│  │  Result: No forbidden files changed
│  └─ Emit: git_state.after_ok (after_policy=warn)
│  └─ Return: 0 (success, continue to next stage)
│
└─ Dispatch result: SUCCESS
```

### Error Path: Dirty Before Stage (Auto-Stash)

```
Stage: Build (in daemon mode, SHIPWRIGHT_DAEMON=1)
│
├─ Before validation
│  ├─ Load manifest for "build"
│  ├─ Run: git status --porcelain
│  │  Output:
│  │    ?? .env.local
│  │    M package-lock.json
│  ├─ Compare against forbidden_paths
│  │  Result: MATCH — .env* is forbidden
│  ├─ Read policy: before_policy = "auto_stash" (manifest declares this stage allows stashing)
│  ├─ Since SHIPWRIGHT_DAEMON=1 AND before_policy=auto_stash:
│  │  ├─ Call: _auto_stash_dirty "build"
│  │  │  ├─ git stash push -u -m "shipwright:pre-build:1715761575:$$"
│  │  │  ├─ Record stash in .claude/pipeline-artifacts/git-validator-stashes.jsonl
│  │  │  └─ Return: 0 (success)
│  │  └─ Emit: git_state.before_stashed (stash_ref=shipwright:pre-build:...)
│  │  └─ Return: 0 (success, proceed to stage)
│
├─ [Stage executes with clean tree]
│  └─ npm run build
│
├─ After validation (success path, same as happy path)
│
└─ Dispatch result: SUCCESS (with auto-stash side effect)
```

### Error Path: Dirty Before Stage (Abort)

```
Stage: PR (before_policy=abort, not in daemon mode)
│
├─ Before validation
│  ├─ Load manifest for "pr"
│  ├─ Run: git status --porcelain
│  │  Output:
│  │    M src/index.js
│  ├─ Compare against forbidden_paths
│  │  Result: MATCH — src/** is forbidden for PR stage
│  ├─ Read policy: before_policy = "abort"
│  ├─ Since before_policy=abort AND (SHIPWRIGHT_DAEMON != 1 AND CI != true):
│  │  ├─ Call: _format_recovery_hint "pr" "$dirty_files"
│  │  │  └─ Stderr output:
│  │  │      ✗ git state validation failed before stage: pr
│  │  │        uncommitted: 1 file
│  │  │      Top offenders:
│  │  │        M src/index.js
│  │  │      Recovery:
│  │  │        git stash && shipwright pipeline resume
│  │  │        # or, to discard changes:
│  │  │        git checkout -- src/index.js
│  │  ├─ Emit: git_state.before_fail
│  │  └─ Return: 1 (abort)
│
├─ Dispatcher catches return=1:
│  ├─ Set: LAST_STAGE_ERROR_CLASS="git_state_dirty"
│  ├─ Classify error: "git_state_dirty" is non-retryable
│  └─ Short-circuit retry loop, return 1
│
└─ Dispatch result: FAILURE (user must stash/checkout and resume)
```

### Error Path: Unexpected File After Stage (Warn)

```
Stage: Build (after_policy=warn)
│
├─ Before validation (success)
│
├─ [Stage executes]
│  └─ npm run build && touch .DS_Store (accidental)
│
├─ After validation
│  ├─ Load manifest for "build"
│  ├─ Diff: git diff --name-only <pre_sha>..HEAD
│  │  Output:
│  │    dist/index.js
│  │    .DS_Store (← unexpected!)
│  ├─ Check against expected_paths (dist/**, .coverage/**)
│  │  Result: .DS_Store NOT in expected_paths
│  ├─ Check against forbidden_paths
│  │  Result: .DS_Store is untracked (not in forbidden_paths match)
│  ├─ Read policy: after_policy = "warn"
│  ├─ Since after_policy=warn:
│  │  ├─ Emit: git_state.after_warn (unexpected_file=.DS_Store)
│  │  └─ Return: 0 (continue, don't abort)
│
└─ Dispatch result: SUCCESS (warn logged, human reviews later via events)
```

---

## 9. Error Boundaries

### Who Handles What Errors

| Error Type                       | Detected By                  | Handling                      | Result               | Emit Event                                          |
| -------------------------------- | ---------------------------- | ----------------------------- | -------------------- | --------------------------------------------------- |
| **Untracked forbidden files**    | `git status` before stage    | Abort or auto-stash (policy)  | Return 1 or 0        | `before_fail` \| `before_stashed`                   |
| **Uncommitted changes**          | `git status` before stage    | Abort or auto-stash (policy)  | Return 1 or 0        | `before_fail` \| `before_stashed`                   |
| **Unexpected file modified**     | `git diff` after stage       | Warn (policy)                 | Return 0             | `after_warn`                                        |
| **Forbidden file modified**      | `git diff` + forbidden_paths | Abort (strict policy)         | Return 1             | `after_fail`                                        |
| **Manifest missing**             | jq parse                     | Error logged, return 1        | Abort stage          | `git_state.before_fail` (reason=manifest_not_found) |
| **Manifest corrupt JSON**        | jq parse                     | Error logged, return 1        | Abort stage          | `git_state.before_fail` (reason=manifest_invalid)   |
| **Stash push fails** (disk full) | `git stash`                  | Escalate to abort             | Return 1             | `git_state.before_fail` (reason=stash_push_failed)  |
| **Git not available**            | `git` command                | Return 0 (no-op if git fails) | Continue (safeguard) | `git_state.before_warn` (reason=git_unavailable)    |

### Error Propagation

```
validate_before_stage()
  └─ Return 1 (abort)
     │
     └─→ run_stage_with_retry()
         └─ LAST_STAGE_ERROR_CLASS="git_state_dirty"
            │
            └─→ classify_error() [existing function]
                └─ "git_state_dirty" → NON-RETRYABLE
                   │
                   └─→ Exit retry loop
                       └─→ Pipeline pauses
                           │
                           └─→ Human action required (stash, resume, or skip stage)

validate_after_stage()
  └─ Return 0 or 1 (caller uses || true, so always succeeds)
     │
     └─→ Event emitted
         └─→ Logged but doesn't affect dispatch
             └─→ Human or metrics system reviews later
```

### Error Recovery Strategies

| Error                                     | Recovery Strategy                          | User Action                                                                                            |
| ----------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| **Forbidden file untracked before stage** | Auto-stash (daemon) or abort (interactive) | If abort: `git stash && shipwright pipeline resume`                                                    |
| **Uncommitted changes before stage**      | Abort (all stages in strict mode)          | `git commit -m "wip"` and `shipwright pipeline resume`                                                 |
| **Unexpected file after stage**           | Warn (logged, not fatal)                   | Review event, consider adding to manifest or `.gitignore`                                              |
| **Manifest missing/corrupt**              | Abort                                      | Check `.claude/pipeline-artifacts/stage-manifests.json` is valid JSON; run `jq . stage-manifests.json` |
| **Git unavailable**                       | Warn (continue)                            | Usually means no repo; local-mode fallback; continue                                                   |

---

## 10. Risk Analysis & Mitigation

### Risk 1: False Positives (Manifest Drift)

**Risk**: As repo evolves, stages output new legitimate files (coverage reports, docs) that don't match manifest. After-validation warns/aborts incorrectly.

**Severity**: 🟡 MEDIUM — Causes false pipeline failures, reduces confidence in validator.

**Mitigation**:

1. Start all manifests in `warn` mode (not `abort`); tighten deliberately via PRs with sign-off.
2. Track false-positive rate via `git_state.after_warn` event counts in DORA dashboard.
3. Provide `SW_DOWNGRADE_GIT_VALIDATOR=warn` global escape hatch for on-call (forces all policies to warn).
4. Document process: PRs that change stage behavior should update manifest in same PR.

**Residual Risk**: 🟢 LOW — Mitigated by gradual tightening and escape hatch.

---

### Risk 2: Stale Stash Leak (Concurrency)

**Risk**: Two parallel pipelines on different worktrees both call `_auto_stash_dirty` concurrently. Both try to write `.claude/pipeline-artifacts/git-validator-stashes.jsonl`; one loses data.

**Severity**: 🔴 HIGH — Data loss (stash metadata lost), user can't pop stash later.

**Mitigation**:

1. Atomic write via tmp + `mv` (identical pattern to existing `scripts/lib/compat.sh` atomicity).
2. Stash message includes worktree path + PID: `shipwright:pre-build:1715761575:$$:$worktree_path` — prevents popping wrong stash.
3. No auto-pop in validator (stashes accumulate, cleaned up separately by `sw-cleanup --gc`).
4. Each worktree has isolated working state; `git status` already per-worktree.

**Residual Risk**: 🟢 LOW — Atomic writes + PID/path isolation prevent collision.

---

### Risk 3: Pipeline Lockup on Dirty State

**Risk**: Before-validation returns abort; dispatcher sets `LAST_STAGE_ERROR_CLASS="git_state_dirty"`. Retry loop checks this class, skips retries. But if dirty state is persistent (e.g., file with permission error), pipeline halts indefinitely.

**Severity**: 🟡 MEDIUM — Pipeline hangs, requires manual recovery.

**Mitigation**:

1. Dispatcher already handles non-retryable error classes (e.g., `configuration`). Mirror that behavior: `git_state_dirty` is non-retryable.
2. Recovery hint includes actionable commands (`git stash`, `git checkout -- .`).
3. `SW_DISABLE_GIT_VALIDATOR=1` escape hatch for emergencies (skip all validation, proceed at risk).
4. Event emission logs the exact dirty files so on-call can diagnose.

**Residual Risk**: 🟢 LOW — Established pattern in existing code, escape hatch available.

---

### Risk 4: Performance Impact

**Risk**: Validator adds `git status` + `git diff` calls (~30ms each) per stage. 14 stages × 30ms = 420ms per pipeline run. On slow repos, could exceed stage timeouts.

**Severity**: 🟢 LOW — 420ms negligible on typical pipeline runtime (5–20 min).

**Mitigation**:

1. Benchmark on this repo: `time git status --porcelain` and `time git diff --name-only HEAD~1..HEAD` both ~30ms.
2. No caching (manifest parsed per call, but that's O(1) with jq and <1ms).
3. Disable via `SW_DISABLE_GIT_VALIDATOR=1` if needed (last resort).

**Residual Risk**: 🟢 LOW — Empirically fast, no caching needed.

---

### Risk 5: Bash 3.2 Compatibility

**Risk**: Developer uses bash 4+ feature (`declare -A`, `${var,,}`) in validator or manifest processing. Script breaks on CI (bash 3.2 only).

**Severity**: 🟡 MEDIUM — Silent failure, caught only in CI or on Mac.

**Mitigation**:

1. Validator uses only bash 3.2 features: `case` for glob matching (not arrays), `jq` for JSON (not bash builtins).
2. Code review checklist: no `declare -A`, no `readarray`, no `${var^^}` / `${var,,}`.
3. Linter: `shellcheck -S warning` catches many bash 4+ uses.
4. Test on both bash 3.2 and 5.x.

**Residual Risk**: 🟡 MEDIUM — Requires diligence in code review; no automated enforcement beyond shellcheck.

---

### Risk 6: Worktree State Isolation

**Risk**: Two worktrees on same repo, same branch. Worktree A stashes a file; Worktree B's `git status` shows the stashed object. Confusion about which worktree owns the stash.

**Severity**: 🟡 MEDIUM — Confusing for users, but not data loss (stash metadata is clear).

**Mitigation**:

1. Stash message includes worktree path: `shipwright:pre-build:1715761575:$$:/path/to/.claude/worktrees/branch-name`
2. Each worktree has isolated working state; stashes are per-repo so visible across worktrees, but metadata makes ownership clear.
3. Users should use `git stash list` to find their stash before popping.
4. Don't auto-pop stashes in validator; human reviews and pops explicitly.

**Residual Risk**: 🟢 LOW — Metadata isolation sufficient; no auto-pop reduces confusion.

---

### Risk 7: LOCAL_MODE Downgrade Behavior

**Risk**: Developer runs `LOCAL_MODE=1 shipwright pipeline ...` expecting git validation to be permissive. But if an old stage function still calls validation directly (before this PR), LOCAL_MODE might not be passed down. Result: unexpected strict validation in local mode.

**Severity**: 🟢 LOW — Only affects future manual hook calls (not in MVP); MVP uses dispatcher decorator only.

**Mitigation**:

1. MVP uses decorator pattern (dispatcher wraps all stages). No per-stage hook calls.
2. If we ever add per-stage hooks, they must check `LOCAL_MODE` environment (inherited from dispatcher).
3. Document in `.claude/CLAUDE.md`: "LOCAL_MODE downgrades all git_state validators to warn mode."

**Residual Risk**: 🟢 LOW — Architectural isolation in dispatcher prevents this risk.

---

## 11. Testing Strategy

### Unit Tests (8 tests in `sw-git-state-validator-test.sh`)

```bash
test_manifest_parses_valid_json
  # Assert: jq . stage-manifests.json succeeds
  # Assert: All 14 stage keys present

test_before_clean_passes
  # Setup: git init, clean tree
  # Call: validate_before_stage "build"
  # Assert: Return 0, event=git_state.before_ok

test_before_dirty_auto_stash_daemon
  # Setup: SHIPWRIGHT_DAEMON=1, untracked file
  # Call: validate_before_stage "build"
  # Assert: Return 0, git stash called, event=git_state.before_stashed

test_before_dirty_abort_interactive
  # Setup: No daemon flags, untracked forbidden file
  # Call: validate_before_stage "pr"
  # Assert: Return 1, recovery hint on stderr, event=git_state.before_fail

test_before_local_mode_downgrade
  # Setup: LOCAL_MODE=1, abort policy, untracked file
  # Call: validate_before_stage "pr"
  # Assert: Return 0 (warn instead of abort), event=git_state.before_warn

test_after_unexpected_file_warn
  # Setup: Stage modified unexpected file, after_policy=warn
  # Call: validate_after_stage "build" "$pre_sha"
  # Assert: Return 0, event=git_state.after_warn

test_disable_escape_hatch
  # Setup: SW_DISABLE_GIT_VALIDATOR=1
  # Call: validate_before_stage "build" with dirty tree
  # Assert: Return 0, no event, no-op

test_all_14_stages_have_manifest
  # Assert: All 14 stages present in manifest
  # Assert: Each has before_policy and after_policy
```

### Integration Test (1 test in new test file)

```bash
test_dispatcher_wraps_stage_with_validation
  # Setup: Mock stage_build() that writes untracked file to forbidden_paths
  # Setup: Manifest forbids src/**/*.tmp
  # Call: run_stage_with_retry "build"
  # Assert: Before-validation catches dirty, returns 1
  # Assert: LAST_STAGE_ERROR_CLASS="git_state_dirty"
  # Assert: Stage never executes
```

### Regression Tests (Run existing suites)

```bash
scripts/sw-pipeline-test.sh                 # Full pipeline E2E
scripts/sw-lib-pipeline-stages-test.sh      # Stage functions
scripts/sw-loop-test.sh                     # Build loop (dispatcher integration)
scripts/sw-daemon-test.sh                   # Daemon + stages
```

**Expected**: All tests pass (validator is additive, doesn't break existing behavior).

---

## 12. Definition of Done

- ✅ `scripts/lib/git-state-validator.sh` created, bash 3.2 compatible, 100% branch coverage in unit tests
- ✅ `.claude/pipeline-artifacts/stage-manifests.json` created, jq-valid, all 14 stages defined
- ✅ `scripts/lib/pipeline-execution.sh` modified (~25 lines), dispatcher wraps stages with before/after validation
- ✅ `scripts/sw-git-state-validator-test.sh` created with 8 unit + 1 integration test
- ✅ `package.json` updated: new test script registered
- ✅ `.claude/CLAUDE.md` updated: Shared Libraries table + Git State Validation subsection
- ✅ `npm test` passes (all 102 suites green, no regressions)
- ✅ `shipwright docs check` reports no stale AUTO sections
- ✅ Manual smoke test in worktree: `touch .env && shipwright pipeline start --issue 0 --local` → validates abort + recovery hint

---

## 13. Future Extensions (Out of Scope for MVP)

1. **Auto-cleanup daemon** (`sw-cleanup --gc`): Sweep stashes older than 7 days
2. **Interactive recovery** (`shipwright git stash pop`): Wrapper around `git stash pop` with metadata lookup
3. **Manifest generation** (`shipwright prep --git-validator`): Auto-generate manifest from stage analysis
4. **CI enforcement** (GitHub Check Run): Emit GitHub Check with git_state events; block merge if too many warnings
5. **Manifest versioning**: Support manifest upgrades across pipeline versions

These are follow-up issues; not part of this ADR.

---

## 14. Appendix: Example Manifest (Complete)

```json
{
  "version": "1.0",
  "description": "Pipeline stage git-state expectations and validation policies",
  "stages": {
    "intake": {
      "description": "GitHub issue intake: create task list, capture scope",
      "expected_paths": [".claude/pipeline-artifacts/intake.json"],
      "forbidden_paths": ["node_modules/**", ".env*", "dist/**", "src/**"],
      "before_policy": "auto_stash",
      "after_policy": "warn"
    },
    "plan": {
      "description": "Task planning: break down work into subtasks",
      "expected_paths": [
        ".claude/pipeline-artifacts/plan.md",
        ".claude/tasks.json"
      ],
      "forbidden_paths": ["node_modules/**", ".env*", "src/**"],
      "before_policy": "auto_stash",
      "after_policy": "warn"
    },
    "design": {
      "description": "Architecture design: interfaces, data models, API contracts",
      "expected_paths": [
        ".claude/pipeline-artifacts/design.md",
        ".claude/adr-*.md"
      ],
      "forbidden_paths": ["node_modules/**", ".env*", "src/**"],
      "before_policy": "auto_stash",
      "after_policy": "warn"
    },
    "spec_generation": {
      "description": "Generate acceptance criteria and spec from design",
      "expected_paths": [".claude/pipeline-artifacts/spec.json"],
      "forbidden_paths": ["node_modules/**", ".env*", "src/**"],
      "before_policy": "auto_stash",
      "after_policy": "warn"
    },
    "build": {
      "description": "Compile, bundle, output to dist/",
      "expected_paths": [
        "dist/**/*.js",
        "dist/**/*.map",
        ".claude/pipeline-artifacts/build.log"
      ],
      "forbidden_paths": ["node_modules/**", ".env*", "*.tmp", ".git/**"],
      "before_policy": "auto_stash",
      "after_policy": "warn"
    },
    "test": {
      "description": "Run test suite, generate coverage",
      "expected_paths": [
        ".coverage/**",
        "coverage/**",
        ".claude/pipeline-artifacts/test-results.log"
      ],
      "forbidden_paths": ["node_modules/**", ".env*"],
      "before_policy": "auto_stash",
      "after_policy": "warn"
    },
    "review": {
      "description": "Code review: architecture, style, security",
      "expected_paths": [".claude/pipeline-artifacts/review.md"],
      "forbidden_paths": ["src/**", "scripts/**", "node_modules/**"],
      "before_policy": "abort",
      "after_policy": "abort"
    },
    "spec_verification": {
      "description": "Verify implementation matches spec",
      "expected_paths": [".claude/pipeline-artifacts/spec-verification.md"],
      "forbidden_paths": ["src/**", "node_modules/**"],
      "before_policy": "abort",
      "after_policy": "abort"
    },
    "compound_quality": {
      "description": "Multi-stage quality checks: security, performance, architecture",
      "expected_paths": [".claude/pipeline-artifacts/compound-quality.md"],
      "forbidden_paths": ["src/**", "node_modules/**"],
      "before_policy": "abort",
      "after_policy": "abort"
    },
    "pr": {
      "description": "Create or update pull request",
      "expected_paths": [],
      "forbidden_paths": ["src/**", "scripts/**", "node_modules/**", ".env*"],
      "before_policy": "abort",
      "after_policy": "abort"
    },
    "merge": {
      "description": "Auto-merge PR to main (gated)",
      "expected_paths": [],
      "forbidden_paths": ["src/**", "scripts/**", "node_modules/**", ".env*"],
      "before_policy": "abort",
      "after_policy": "abort"
    },
    "deploy": {
      "description": "Deploy to staging/production",
      "expected_paths": [],
      "forbidden_paths": [],
      "before_policy": "warn",
      "after_policy": "warn"
    },
    "validate": {
      "description": "Post-deploy validation: health checks, smoke tests",
      "expected_paths": [
        ".claude/pipeline-artifacts/deployment-validation.log"
      ],
      "forbidden_paths": [],
      "before_policy": "warn",
      "after_policy": "warn"
    },
    "monitor": {
      "description": "Monitor for regressions and rollback triggers",
      "expected_paths": [],
      "forbidden_paths": [],
      "before_policy": "warn",
      "after_policy": "warn"
    }
  }
}
```

---

## 15. Related Documents

- **Pipeline Stages**: `.claude/CLAUDE.md` → "Pipeline Stages" section
- **Error Classification**: `scripts/lib/pipeline-execution.sh::classify_error()`
- **Event System**: `scripts/lib/helpers.sh::emit_event()`
- **Atomic Writes**: `scripts/lib/compat.sh` — atomic file operations
- **Worktree Management**: `scripts/sw-worktree.sh` and `scripts/lib/pipeline-execution.sh`

---

**Signed Off By**: Shipwright Design Team  
**Status**: Ready for Implementation (Phase 1: Files 1–5, Tasks 1–5)  
**Next Step**: Proceed with Task 1 (Manifest Schema) →
