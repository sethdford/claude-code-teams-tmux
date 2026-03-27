# Pre-Flight Validation Suite with Cost-Saving Smart Abort

## Implementation Plan

---

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change:** Create a new `scripts/lib/pipeline-preflight.sh` module that replaces the existing `preflight_checks()` function in `scripts/lib/pipeline-util.sh`. The new module reads configurable checks from `.claude/pre-flight-checks.json`, runs tiered validations (fast to slow), and aborts with actionable remediation messages. Add a standalone `sw-preflight.sh` command.

**Implicit requirements:**
- Must not break existing `pipeline_start()` flow — the enhanced check replaces the current `preflight_checks()` call at line 536 of `pipeline-commands.sh`
- Must respect `$NO_GITHUB` guard for any GitHub API calls
- Must be Bash 3.2 compatible (no associative arrays, no `readarray`, no `${var,,}`)
- Must complete in <60 seconds total
- Must emit events via `emit_event` for observability
- Must integrate with cost tracking — log estimated cost savings on abort

### Alternatives Considered

**Approach A: Enhance existing `preflight_checks()` inline**
- Pros: Minimal blast radius (1 file changed + 1 new config), reuses existing call site
- Cons: `pipeline-util.sh` grows; limited standalone usability
- Blast radius: Low

**Approach B: New pipeline stage `preflight` at position 0**
- Pros: Visible in pipeline state, gets GitHub Check Run, follows stage pattern
- Cons: Requires modifying all 8 pipeline template JSONs, changes stage sequencing logic. `preflight_checks()` is called *before* `load_pipeline_config()` so the stage system isn't even available yet
- Rejected: The current call site (before config load, before state init) is architecturally correct — validation must happen before the pipeline machinery starts

**Approach C: Separate library `lib/pipeline-preflight.sh` (chosen)**
- Pros: Clean separation of concerns, follows existing `pipeline-*.sh` decomposition pattern, enables standalone CLI command
- Cons: One more lib file to maintain (acceptable — the project already has 21 pipeline lib modules)
- Blast radius: Low — new file + thin wrapper replacement in pipeline-util.sh

### Final Decision
**Approach C** — Create `scripts/lib/pipeline-preflight.sh` as a dedicated module. The existing `preflight_checks()` in `pipeline-util.sh` is replaced with a thin wrapper that delegates to `preflight_run()` from the new module. Falls back to basic checks if module is unavailable.

---

## Architecture Decision Record

### Component Diagram

```
                    ┌──────────────────────────────┐
                    │   sw-pipeline.sh (entry)      │
                    │   sources lib/pipeline-util.sh│
                    └──────────┬───────────────────┘
                               │ pipeline_start()
                               │ calls preflight_checks()
                               ▼
┌─────────────────────────────────────────────────────────┐
│            lib/pipeline-preflight.sh                     │
│                                                          │
│  preflight_run()             ← orchestrator              │
│    ├── load_preflight_config() ← reads JSON config       │
│    ├── run_tier1_checks()    ← instant (<1s)             │
│    │     ├── check_required_tools()                      │
│    │     ├── check_git_repo()                            │
│    │     └── check_disk_space()                          │
│    ├── run_tier2_checks()    ← fast (<10s)               │
│    │     ├── check_git_state()                           │
│    │     ├── check_base_branch()                         │
│    │     ├── check_env_vars()                            │
│    │     └── check_claude_cli()                          │
│    ├── run_tier3_checks()    ← medium (<30s)             │
│    │     ├── check_github_auth()                         │
│    │     ├── check_dependencies()                        │
│    │     └── check_smoke_test()                          │
│    └── preflight_abort()     ← formatted abort + event   │
│                                                          │
│  Config: .claude/pre-flight-checks.json                  │
└─────────────────────────────────────────────────────────┘
                               │
                               ▼
┌────────────────────────────────────────┐
│  sw-preflight.sh (standalone command)  │
│  sources lib/pipeline-preflight.sh     │
│  CLI: shipwright preflight [--fix]     │
└────────────────────────────────────────┘
                               │
                               ▼
┌────────────────────────────────────────┐
│  sw-preflight-test.sh (test suite)     │
│  Mocks each check, validates abort     │
└────────────────────────────────────────┘
```

### Interface Contracts

```bash
# Main orchestrator — called from pipeline_start() via preflight_checks() wrapper
# Returns: 0 on pass, 1 on failure (with remediation printed)
# Side effects: emits events, writes preflight-report.json artifact
preflight_run()

# Load and merge config: defaults + .claude/pre-flight-checks.json
# Sets global: PREFLIGHT_CONFIG (JSON string)
# Returns: 0 always (missing config = use defaults)
load_preflight_config()

# Tier runners — each returns 0 on pass, 1 on any failure
# Side effects: increments $preflight_errors counter, prints check results
run_tier1_checks()  # tools, git repo, disk — abort immediately on fail
run_tier2_checks()  # git state, branch, env vars, CLI — abort on fail
run_tier3_checks()  # github auth, deps, smoke test — abort on fail

# Individual checks — return 0 pass, 1 fail
# Side effects: print pass/fail line, append to PREFLIGHT_REMEDIATIONS
check_required_tools()
check_git_repo()
check_disk_space()
check_git_state()
check_base_branch()
check_env_vars()
check_claude_cli()
check_github_auth()
check_dependencies()
check_smoke_test()

# Abort handler — prints remediation + emits cost-saving event
# Args: $1=error_count $2=tier_that_failed
# Returns: 1 always
preflight_abort()
```

### Data Flow

```
1. pipeline_start() → preflight_checks() [pipeline-util.sh wrapper]
2. preflight_checks() → preflight_run() [pipeline-preflight.sh]
3. preflight_run() → load_preflight_config()
   reads: .claude/pre-flight-checks.json (optional, defaults if missing)
   produces: PREFLIGHT_CONFIG variable (JSON string)
4. preflight_run() → run_tier1_checks() → run_tier2_checks() → run_tier3_checks()
   each tier: runs enabled checks, accumulates errors + remediations
   short-circuit: if tier N fails and fail_fast=true, skip tier N+1
5. On failure: preflight_abort()
   writes: .claude/pipeline-artifacts/preflight-report.json
   emits: pipeline.preflight_failed event with error details
   prints: boxed remediation steps + estimated cost saved
6. On success:
   writes: .claude/pipeline-artifacts/preflight-report.json (all passed)
   emits: pipeline.preflight_passed event with duration
   returns 0 → pipeline proceeds to gh_init/load_pipeline_config
```

### Error Boundaries

- **Tool check failures**: Caught by `command -v`, reported with install instructions
- **Git failures**: Caught by `git` exit codes, reported with fix commands
- **GitHub auth failures**: Caught by `gh auth status`, guarded by `$NO_GITHUB`
- **Dependency check failures**: Caught by file existence checks (not `npm install`), reported with install commands
- **Smoke test failures**: Caught by test command exit code, reported with "fix tests first"
- **Config parse failures**: `jq` errors caught, falls back to defaults with warning
- **Timeout**: Individual checks get a 15-second timeout via the existing `_timeout` helper

---

## Files to Modify

### New Files
1. **`scripts/lib/pipeline-preflight.sh`** — Core pre-flight validation module (~350 lines)
2. **`scripts/sw-preflight.sh`** — Standalone CLI command (~120 lines)
3. **`scripts/sw-preflight-test.sh`** — Test suite (~500 lines)

### Modified Files
4. **`scripts/lib/pipeline-util.sh`** — Replace `preflight_checks()` (lines 255-359) with thin wrapper
5. **`scripts/sw-pipeline.sh`** — Add source line for `pipeline-preflight.sh`
6. **`scripts/sw`** — Add `preflight` subcommand routing

---

## Implementation Steps

### Step 1: Create `scripts/lib/pipeline-preflight.sh`

The core module. Key implementation details:

**Module header:**
```bash
#!/usr/bin/env bash
# Module: pipeline-preflight
# Pre-flight validation suite with tiered checks and cost-saving smart abort
set -euo pipefail

# Module guard
[[ -n "${_MODULE_PIPELINE_PREFLIGHT_LOADED:-}" ]] && return 0
_MODULE_PIPELINE_PREFLIGHT_LOADED=1

VERSION="3.2.4"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
```

**Default config** (built into the module, overridden by `.claude/pre-flight-checks.json`):
```json
{
  "enabled": true,
  "fail_fast": true,
  "timeout_seconds": 60,
  "checks": {
    "required_tools": { "enabled": true, "tools": ["git", "jq"] },
    "optional_tools": { "enabled": true, "tools": ["gh", "claude", "bc", "curl"] },
    "git_repo": { "enabled": true },
    "git_clean": { "enabled": true, "auto_stash": false },
    "base_branch": { "enabled": true },
    "disk_space_mb": { "enabled": true, "minimum_mb": 1024 },
    "env_vars": { "enabled": true, "required": [], "optional": ["GITHUB_TOKEN", "ANTHROPIC_API_KEY"] },
    "claude_cli": { "enabled": true },
    "github_auth": { "enabled": true },
    "dependencies": { "enabled": true, "auto_install": false },
    "smoke_test": { "enabled": false, "command": "", "timeout_seconds": 30 }
  },
  "estimated_pipeline_cost_usd": 5.0
}
```

**Tier 1 checks** (instant, <1s — abort immediately if these fail):
- `check_required_tools()`: Verify `git`, `jq` exist (configurable list). Remediation: platform-specific install command
- `check_git_repo()`: Verify `git rev-parse --is-inside-work-tree`. Remediation: "Run from inside a git repository"
- `check_disk_space()`: Compare `df -k` against configured minimum. Remediation: "Free up disk space (need Xmb, have Ymb)"

**Tier 2 checks** (fast, <10s):
- `check_git_state()`: Check uncommitted changes via `git status --porcelain`. Auto-stash if `auto_stash=true` or `SKIP_GATES=true`. Remediation: "Commit or stash changes: git stash"
- `check_base_branch()`: Verify `$BASE_BRANCH` exists via `git rev-parse --verify`. Remediation: "Fetch base branch: git fetch origin main"
- `check_env_vars()`: Loop through configured `required` env vars. Remediation: "Set missing env var: export VAR=value"
- `check_claude_cli()`: Verify `claude` command exists and sw-loop.sh is executable. Remediation: "Install Claude CLI"

**Tier 3 checks** (medium, <30s):
- `check_github_auth()`: Run `gh auth status` (guarded by `$NO_GITHUB`). Remediation: "Authenticate: gh auth login"
- `check_dependencies()`: Auto-detect project type and verify deps installed — check `node_modules/` for Node.js, `vendor/` for Go, `venv/` or `.venv/` for Python. Does NOT run `npm install` (that's `--fix` mode). Remediation: "Run: npm install"
- `check_smoke_test()`: Run configured smoke test command with timeout. Remediation: "Fix failing tests before running pipeline"

**Abort handler** (`preflight_abort`):
- Print boxed error summary with all collected remediations
- Calculate and display estimated cost saved (from config `estimated_pipeline_cost_usd`)
- Emit `pipeline.preflight_failed` event
- Write `preflight-report.json` artifact with structured results
- Return 1

**Success handler**:
- Print timing summary (e.g., "Pre-flight passed in 2.3s")
- Emit `pipeline.preflight_passed` event with duration
- Write `preflight-report.json` artifact
- Return 0

### Step 2: Update `scripts/lib/pipeline-util.sh`

Replace the existing `preflight_checks()` function (lines 255-359) with a thin wrapper:

```bash
preflight_checks() {
    # Delegate to the preflight module if loaded
    if [[ "$(type -t preflight_run 2>/dev/null)" == "function" ]]; then
        preflight_run
    else
        warn "Pre-flight module not loaded — running basic checks"
        _preflight_checks_basic
    fi
}

# Fallback: original basic checks (subset of the original)
_preflight_checks_basic() {
    local errors=0
    for tool in git jq; do
        command -v "$tool" >/dev/null 2>&1 || { error "$tool not found"; errors=$((errors + 1)); }
    done
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { error "Not in git repo"; errors=$((errors + 1)); }
    [[ "$errors" -gt 0 ]] && return 1
    return 0
}
```

### Step 3: Update `scripts/sw-pipeline.sh`

Add source line for the preflight module (after the existing `pipeline-util.sh` source around line 137):

```bash
# shellcheck source=lib/pipeline-preflight.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-preflight.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-preflight.sh"
```

### Step 4: Create `scripts/sw-preflight.sh`

Standalone CLI command:

```bash
#!/usr/bin/env bash
# shipwright preflight — Pre-flight validation for pipeline readiness
# Usage: shipwright preflight [--fix] [--config path] [--json]
```

- `--fix`: Attempt auto-remediation (install deps, stash changes, fetch branches)
- `--config`: Override config file path
- `--json`: Output results as JSON
- `--help`: Usage info
- Sources required libs and calls `preflight_run`

### Step 5: Update `scripts/sw` CLI Router

Add `preflight` to the case statement in the CLI router.

### Step 6: Create `scripts/sw-preflight-test.sh`

Test suite following established patterns. Uses temp directory with mock git repo and mock binaries.

**Test cases (22 total):**

| # | Test | Type | What it validates |
|---|------|------|-------------------|
| 1 | `test_preflight_passes_clean_env` | Unit | All checks pass on clean setup |
| 2 | `test_preflight_fails_no_git` | Unit | Missing git → tier 1 abort with remediation |
| 3 | `test_preflight_fails_no_jq` | Unit | Missing jq → tier 1 abort with remediation |
| 4 | `test_preflight_fails_not_git_repo` | Unit | Not in git repo → abort |
| 5 | `test_preflight_fails_low_disk_space` | Unit | Low disk → abort with space info |
| 6 | `test_preflight_fails_dirty_tree` | Unit | Uncommitted changes → abort with stash hint |
| 7 | `test_preflight_auto_stash` | Unit | auto_stash=true → changes stashed, continues |
| 8 | `test_preflight_auto_stash_skip_gates` | Unit | SKIP_GATES=true → auto-stash |
| 9 | `test_preflight_fails_base_branch_missing` | Unit | Base branch not found → abort |
| 10 | `test_preflight_fails_missing_env_var` | Unit | Required env var missing → abort |
| 11 | `test_preflight_fails_empty_env_var` | Unit | Required env var empty → abort |
| 12 | `test_preflight_fails_no_claude` | Unit | Claude CLI missing → abort |
| 13 | `test_preflight_fails_github_auth` | Unit | gh auth fails → abort |
| 14 | `test_preflight_skips_github_when_disabled` | Unit | NO_GITHUB=true → skips gh checks |
| 15 | `test_preflight_fails_no_deps` | Unit | node_modules missing → abort |
| 16 | `test_preflight_fails_smoke_test` | Unit | Smoke test fails → abort |
| 17 | `test_preflight_smoke_test_timeout` | Unit | Smoke test hangs → timeout abort |
| 18 | `test_preflight_custom_config` | Integration | Custom JSON config overrides defaults |
| 19 | `test_preflight_missing_config_defaults` | Integration | No config file → defaults |
| 20 | `test_preflight_invalid_config_warns` | Integration | Malformed JSON → warning + defaults |
| 21 | `test_preflight_tier_short_circuit` | Integration | Tier 1 fail → tiers 2,3 skipped |
| 22 | `test_preflight_cost_saving_message` | Unit | Abort includes cost estimate |

---

## Task Decomposition

1. **Task 1**: Create `scripts/lib/pipeline-preflight.sh` — module guard, globals, `load_preflight_config()`, default config
2. **Task 2**: Implement Tier 1 checks — `check_required_tools()`, `check_git_repo()`, `check_disk_space()`, `run_tier1_checks()`
3. **Task 3**: Implement Tier 2 checks — `check_git_state()`, `check_base_branch()`, `check_env_vars()`, `check_claude_cli()`, `run_tier2_checks()`
4. **Task 4**: Implement Tier 3 checks — `check_github_auth()`, `check_dependencies()`, `check_smoke_test()`, `run_tier3_checks()`
5. **Task 5**: Implement `preflight_abort()` — boxed output, cost savings, event emission, report artifact
6. **Task 6**: Implement `preflight_run()` — tier orchestration with short-circuit, timing, success path
   - Depends on: Tasks 1-5
7. **Task 7**: Update `scripts/lib/pipeline-util.sh` — replace `preflight_checks()` with delegation wrapper + `_preflight_checks_basic()` fallback
   - Depends on: Task 6
8. **Task 8**: Update `scripts/sw-pipeline.sh` — add source line for preflight module
   - Depends on: Task 1
9. **Task 9**: Create `scripts/sw-preflight.sh` — standalone CLI with --fix/--json/--config flags
   - Depends on: Task 6
10. **Task 10**: Update `scripts/sw` — add `preflight` subcommand routing
    - Depends on: Task 9
11. **Task 11**: Create `scripts/sw-preflight-test.sh` — full test suite (22 tests)
    - Depends on: Tasks 1-10
12. **Task 12**: Validate — run test suite, run `shipwright preflight` manually, verify <60s

---

## Definition of Done

- [ ] Pre-flight validation runs before intake stage (at existing call site in `pipeline_start()`)
- [ ] Checks implemented: git clean/branch, tools (git/jq/claude), dependencies (npm/pip/go auto-detect), smoke test, env vars, GitHub token validity
- [ ] Configurable via `.claude/pre-flight-checks.json` with documented schema
- [ ] Abort produces clear error message with per-check remediation steps
- [ ] Abort includes estimated cost savings message
- [ ] Success: validation completes in <60 seconds, pipeline proceeds unchanged
- [ ] Test suite has 20+ tests covering each failure condition and abort behavior
- [ ] Standalone `shipwright preflight` command works with --fix, --json, --config
- [ ] Events emitted: `pipeline.preflight_passed` and `pipeline.preflight_failed`
- [ ] Artifact written: `preflight-report.json`
- [ ] Bash 3.2 compatible (no associative arrays, readarray, etc.)
- [ ] `$NO_GITHUB` respected for all GitHub-related checks
- [ ] Module guard pattern used (idempotent sourcing)
- [ ] Fallback to basic checks if module fails to load

---

## Risk Analysis

| Risk | What Could Break | Mitigation |
|------|-----------------|------------|
| Breaking existing pipeline flow | New `preflight_checks()` has different return semantics | Keep same signature (no args, returns 0/1), fallback to basic checks if module not loaded |
| False positives blocking valid pipelines | Overly strict checks (e.g., requiring clean tree in worktree mode) | Respect `SKIP_GATES` and `AUTO_WORKTREE` flags; every check individually configurable |
| Slow checks exceeding 60s | Smoke test or dependency check hangs | Each check gets a timeout; total budget tracked and enforced |
| Config file corruption | Malformed JSON blocks all pipelines | `jq` parse errors caught, fall back to defaults with warning |
| Bash 3.2 incompatibility | Using bash 4+ features | Strict adherence to project's bash compat rules; no associative arrays, readarray, etc. |
| Module loading failure | Syntax error in new module | Wrapper in pipeline-util.sh detects missing function and falls back to basic checks |

---

## Failure Mode Analysis

### 1. False Positive Abort (HIGH RISK)
**What happens**: A check incorrectly fails, blocking a valid pipeline run. Example: `check_dependencies()` reports "node_modules missing" in a Go project.
**Mitigation**: Project type detection (reuse `detect_project_type` from `pipeline-detection.sh`) gates which dependency checks run. Only check deps matching detected project type. Config override allows disabling any check. The `--fix` flag provides auto-remediation.

### 2. Config File Race Condition (MEDIUM RISK)
**What happens**: In daemon mode with worktrees, the config file is read from the original repo while the pipeline runs in a worktree copy.
**Mitigation**: `load_preflight_config()` reads from `$PROJECT_ROOT` (set to worktree root by `setup_dirs()`). The existing worktree creation hook copies `.claude/` contents. Config read is a single `jq` invocation (atomic).

### 3. Smoke Test Hangs (MEDIUM RISK)
**What happens**: A user-configured smoke test command hangs indefinitely, exceeding the 60s total budget.
**Mitigation**: Wrap smoke test execution in `_timeout` with the configured timeout (default 30s). The timeout kills the subprocess and reports "Test timed out after Xs" with remediation.

### 4. Module Loading Failure (LOW RISK)
**What happens**: `pipeline-preflight.sh` fails to source (syntax error, missing file after upgrade).
**Mitigation**: The wrapper in `pipeline-util.sh` checks `type -t preflight_run` and falls back to `_preflight_checks_basic()` (the original logic preserved as fallback). Pipeline can always start.

**Most critical failure addressed**: False Positive Abort. Implementation mitigates with: (1) every check individually configurable, (2) project type detection prevents irrelevant checks, (3) `SKIP_GATES` flag bypasses non-critical checks, (4) fallback to basic checks if module fails.
