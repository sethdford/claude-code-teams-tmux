# Zero-Config Project Auto-Setup Implementation Plan

**Issue**: #629  
**Goal**: Intelligent one-command setup that detects project type, auto-installs dependencies in parallel, generates optimal configs, creates language-specific agents  
**Target Time**: <5 minutes end-to-end  
**Status**: Planning phase

---

## Brainstorming: Design Analysis

### Requirements Clarity

**Minimum Viable Change**:
A single `shipwright setup --auto` command that:

1. Detects project characteristics (language, framework, package manager, test runner)
2. Installs missing dependencies in parallel with progress feedback
3. Generates `daemon-config.json` tuned to project complexity
4. Creates language-specific agent definitions
5. Validates setup with `shipwright doctor`
6. Completes in <5 minutes

**Implicit Requirements** (derived from issue + context):

- Must be non-interactive (zero-config) — no prompts
- Must work across node/python/go/rust projects
- Must be idempotent (safe to run multiple times)
- Must handle partial/failed installs gracefully
- Must provide clear reporting of what was done
- Should reuse detection logic from existing `sw-prep.sh`

### Design Alternatives

**Alternative 1: Monolithic script** (`scripts/sw-setup-auto.sh`)

- Pros: Single entry point, no dependency injection complexity
- Cons: Hard to test, tight coupling, not reusable
- Blast radius: Any bug affects entire setup flow
- ❌ **Rejected**: Violates single-responsibility and testing principles

**Alternative 2: Modular library pattern** (recommended)

- Pros: Each module testable in isolation, composable, reusable
- Cons: More files, requires clear interfaces
- Blast radius: Each failure is isolated to one module
- ✓ **Selected**: Follows Shipwright's decomposition patterns (see recent PRs)

**Alternative 3: Daemon-driven auto-setup**

- Pros: Could run unattended in background
- Cons: Overengineering for a one-shot operation
- ❌ **Rejected**: Adds complexity not needed for setup

### Risk Assessment

**Key Risks Identified**:

1. **Parallel install race conditions** — Multiple attempts to install the same tool could corrupt state
2. **Network timeout during CLI installs** — gh/Claude CLI require internet, could hang
3. **Incomplete language detection** — Missing framework files could produce wrong configuration
4. **Output bloat in generated configs** — Auto-generated configs could exceed 10KB, breaking JSON parsing
5. **Agent template conflicts** — Multiple language agents could overwrite each other

### Dependency Analysis

**Existing code this depends on**:

- `scripts/lib/compat.sh` — cross-platform helpers
- `scripts/lib/helpers.sh` — info/success/error output, event logging
- `scripts/lib/project-detect.sh` — project detection (will reuse/enhance)
- `scripts/sw-doctor.sh` — validation command
- `.claude/agents/*.md` — existing agent templates

**What depends on this**:

- New `shipwright setup --auto` command
- Potentially `shipwright init` could call this for faster setup flow

### Simplicity Check

**Can this be simpler?**

- Yes: Could hardcode one language (Node) to ship faster
- But no: Issue explicitly requires node/python/go/rust support
- Trade-off: Implement modular from start, adds ~20% more code but 10x better testing/maintenance

**Existing patterns to reuse**:

- `sw-prep.sh` detection logic ✓
- `sw-setup.sh` wizard structure ✓
- Helper library patterns ✓
- Agent definition format ✓

---

## Architecture Design Record (ADR)

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│  CLI Entry Point (scripts/sw-setup-auto.sh)                     │
│  - Parse flags, initialize state, orchestrate flow              │
└──────────────────────┬──────────────────────────────────────────┘
                       │
       ┌───────────────┼───────────────┬───────────────┐
       │               │               │               │
       ▼               ▼               ▼               ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ ProjectDetect│ │ DepInstaller │ │ ConfigGenr   │ │ AgentFactory │
│ (lib file)   │ │ (lib file)   │ │ (lib file)   │ │ (lib file)   │
│              │ │              │ │              │ │              │
│ - Scan fs    │ │ - Check inst │ │ - Complexity │ │ - Lang-spe   │
│ - Identify   │ │ - Parallel   │ │ - Effort lvl │ │ - Template   │
│ - Return MD  │ │ - Retry loop │ │ - Tuning     │ │ - Write .md  │
└──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘
       │               │               │               │
       └───────────────┼───────────────┴───────────────┘
                       │
                       ▼
         ┌──────────────────────────┐
         │  Validator (sw-doctor)   │
         │  - Run validation        │
         │  - Report status         │
         └──────────────────────────┘
```

### Component Descriptions

**1. ProjectDetector** (library: `scripts/lib/project-detector.sh`)

- **Responsibility**: Scan filesystem and identify project characteristics
- **Input**: Project root directory
- **Output**: JSON object with {language, framework, packageManager, testRunner, complexity}
- **Complexity Scoring**: 0-100 based on file count, layers, dependencies
- **Error Contract**: Returns `{}` if undetectable, logs warnings

**2. DependencyInstaller** (library: `scripts/lib/dependency-installer.sh`)

- **Responsibility**: Check system for required tools, install in parallel
- **Input**: List of {toolName, checkCmd, installCmd}
- **Output**: JSON with {tool, status, installed, duration_ms}
- **Concurrency**: Semaphore-controlled (max 4 parallel, platform-aware)
- **Error Contract**: Records failures, but doesn't block setup

**3. ConfigGenerator** (library: `scripts/lib/config-generator.sh`)

- **Responsibility**: Create `daemon-config.json` tuned for project
- **Input**: Project metadata (complexity, language, test duration)
- **Output**: `daemon-config.json` at `.claude/daemon-config.json`
- **Idempotency**: Preserves existing settings if file exists (merge mode)
- **Error Contract**: Falls back to defaults, logs what was overridden

**4. AgentFactory** (library: `scripts/lib/agent-factory.sh`)

- **Responsibility**: Generate language-specific agent definitions
- **Input**: Detected language (node/python/go/rust)
- **Output**: `.claude/agents/<language>-specialist.md`
- **Safety**: Non-destructive (append/merge, never overwrite existing)
- **Error Contract**: Silently skips if file exists, logs decision

**5. Orchestrator** (CLI: `scripts/sw-setup-auto.sh`)

- **Responsibility**: Tie modules together, handle timing, report results
- **Flow**:
  1. Detect project (0.1s)
  2. Install deps in parallel (30-90s)
  3. Generate config (0.5s)
  4. Generate agents (1-2s)
  5. Run doctor (10-30s)
  6. Report summary
- **Timing**: Track each phase, warn if >5min

### Interface Contracts

**ProjectDetector Output**:

```bash
{
  "language": "node|python|go|rust|unknown",
  "framework": "express|django|gin|axum|none",
  "packageManager": "npm|pip|go|cargo",
  "testRunner": "vitest|pytest|gotest|cargo-test",
  "sourceFiles": 150,
  "testFiles": 45,
  "complexity": 62
}
```

**DependencyInstaller Output**:

```bash
{
  "duration_ms": 45000,
  "tools": [
    {"name": "tmux", "status": "installed", "was_missing": false},
    {"name": "jq", "status": "installed", "was_missing": true, "install_ms": 18000},
    {"name": "gh", "status": "installed", "was_missing": false},
    {"name": "claude-cli", "status": "installed", "was_missing": true, "install_ms": 35000}
  ]
}
```

**ConfigGenerator Output**:

```bash
daemon-config.json written to .claude/daemon-config.json
{
  "max_parallel": 2,
  "iteration_counts": {
    "build": 8,
    "test": 5
  },
  "timeouts": {
    "build": 600,
    "test": 300
  },
  "effort_levels": {
    "plan": "high",
    "build": "medium"
  }
}
```

---

## Files to Modify

### New Files (Core Implementation)

| File                                  | Purpose                                            |
| ------------------------------------- | -------------------------------------------------- |
| `scripts/lib/project-detector.sh`     | Library: Detect language/framework/package manager |
| `scripts/lib/dependency-installer.sh` | Library: Check and install deps in parallel        |
| `scripts/lib/config-generator.sh`     | Library: Generate tuned daemon-config.json         |
| `scripts/lib/agent-factory.sh`        | Library: Generate language-specific agents         |
| `scripts/sw-setup-auto.sh`            | CLI: Orchestrator entry point                      |
| `scripts/sw-setup-auto-test.sh`       | Test suite: All components + integration           |

### New Files (Documentation/Generated)

| File                                                           | Purpose                           |
| -------------------------------------------------------------- | --------------------------------- |
| `scripts/skills/generated/project-detection-design.md`         | Design doc for detection logic    |
| `scripts/skills/generated/parallel-dependency-installation.md` | Design doc for parallel installer |
| `scripts/skills/generated/setup-config-generation.md`          | Design doc for config generator   |

### Modified Files

| File                  | Changes                                     |
| --------------------- | ------------------------------------------- |
| `scripts/sw`          | Add `setup-auto` command routing            |
| `scripts/sw-setup.sh` | (Optional) Link to new auto command in help |
| `package.json`        | Add test suite to npm test script           |
| `.claude/CLAUDE.md`   | Document new command in CLI reference       |

---

## Implementation Steps

### Phase 1: Foundation (Steps 1-3)

Create the library skeleton and detection logic.

**Step 1: Create ProjectDetector library**

- File: `scripts/lib/project-detector.sh`
- Functions:
  - `detect_language()` — Scan for language indicators (package.json, requirements.txt, go.mod, Cargo.toml)
  - `detect_framework()` — Identify framework (express, django, gin, etc.)
  - `detect_package_manager()` — Identify pkg manager (npm, pip, go, cargo)
  - `detect_test_runner()` — Identify test runner (vitest, pytest, gotest, cargo-test)
  - `score_complexity()` — Count source files, test files, layers → 0-100 score
  - `output_json()` — Produce final JSON output
- Bash 3.2 compatible, use jq for JSON output
- Add verbose logging with `info()` helper
- Test each function independently

**Step 2: Create DependencyInstaller library**

- File: `scripts/lib/dependency-installer.sh`
- Functions:
  - `check_installed(tool)` — Verify tool is installed and accessible
  - `get_install_command(tool, os)` — Return platform-specific install command
  - `install_parallel(tools_array)` — Install multiple tools concurrently
  - `track_semaphore(max_parallel)` — Limit concurrent jobs using semaphore pattern
  - `report_results()` — JSON output with status and timing
- **Key constraint**: Bash 3.2 compatible, no `declare -A` — use `/tmp/semaphore-*` files
- Use `mkfifo` for semaphore pattern or simple file locking
- Retry on failure (max 3 attempts) with exponential backoff
- Timeout after 120s per tool
- Test with mock install commands

**Step 3: Create ConfigGenerator library**

- File: `scripts/lib/config-generator.sh`
- Functions:
  - `calculate_iteration_counts(complexity)` — Return build/test iteration counts based on complexity
  - `calculate_timeouts(project_type)` — Return stage timeouts (adjusted for language)
  - `determine_effort_levels(complexity)` — Return effort levels per stage
  - `generate_config(metadata)` — Generate complete daemon-config.json
  - `merge_with_existing(new_config)` — Merge with existing config if present (idempotent)
  - `write_atomically(path, content)` — Write to tmp file then mv
- **Tuning logic**:
  - Low complexity (0-30): 3 iterations, 300s timeout, low effort
  - Medium complexity (31-70): 5-6 iterations, 600s timeout, medium effort
  - High complexity (71-100): 8+ iterations, 900s timeout, high effort
- **Language adjustments**:
  - Python: Add extra iteration (env setup complexity)
  - Go: Reduce timeout (compiled, faster)
  - Rust: Add extra timeout (compilation slow)
- Test merging logic to ensure idempotency

**Step 4: Create AgentFactory library**

- File: `scripts/lib/agent-factory.sh`
- Functions:
  - `get_agent_template(language)` — Return template for language-specific specialist
  - `generate_agent(language, config)` — Generate agent definition markdown
  - `write_agent_definition(language, content)` — Write to `.claude/agents/<lang>-specialist.md`
  - `is_agent_existing(language)` — Check if agent already exists
- **Agent templates** (inline markdown):
  - `node-specialist.md` — Node/JavaScript rules, npm/vitest patterns
  - `python-specialist.md` — Python rules, pip/pytest patterns
  - `go-specialist.md` — Go rules, go.mod patterns
  - `rust-specialist.md` — Rust rules, cargo patterns
- Non-destructive write (check existence first, log if skipped)
- Test template expansion with variable substitution

### Phase 2: Orchestration (Steps 5-7)

Create CLI and tie modules together.

**Step 5: Create sw-setup-auto.sh orchestrator**

- File: `scripts/sw-setup-auto.sh`
- Main flow:
  1. Parse `--force`, `--check-only` flags
  2. Print welcome banner
  3. Call `detect_language()` → store metadata
  4. Call `install_parallel()` → record timing
  5. Call `generate_config()` → create daemon-config.json
  6. Call `generate_agent()` → create agent definitions
  7. Call `shipwright doctor` for validation
  8. Print summary report
- Output format:
  ```
  ╔════ Zero-Config Setup Complete ════╗
  Language: Node.js (complexity: 62)
  Dependencies: 4 installed (45s)
  Config: daemon-config.json generated
  Agents: node-specialist.md created
  Doctor: ✓ All checks passed
  Time: 1m 24s (within 5m budget)
  Next: shipwright pipeline start --issue 42
  ```
- Exit codes:
  - 0 = full success
  - 1 = validation failed (doctor errors)
  - 2 = missing critical dependency
- Track timing throughout, warn if approaching 5min limit

**Step 6: Route through CLI**

- File: `scripts/sw`
- Add case for `setup-auto`:
  ```bash
  setup-auto)
      exec "$SCRIPT_DIR/sw-setup-auto.sh" "$@"
      ;;
  ```
- Update help text

**Step 7: Create comprehensive test suite**

- File: `scripts/sw-setup-auto-test.sh`
- Structure:
  - `test_node_project_detection()` — Verify Node detection
  - `test_python_project_detection()` — Verify Python detection
  - `test_go_project_detection()` — Verify Go detection
  - `test_rust_project_detection()` — Verify Rust detection
  - `test_dependency_install_sequential()` — Mock installs
  - `test_dependency_install_parallel()` — Mock parallel execution
  - `test_config_generation_idempotency()` — Run twice, verify same result
  - `test_agent_generation_non_destructive()` — Verify no overwrites
  - `test_full_flow_node()` — End-to-end Node project
  - `test_full_flow_python()` — End-to-end Python project
  - `test_full_flow_go()` — End-to-end Go project
  - `test_full_flow_rust()` — End-to-end Rust project
  - `test_missing_dependency_handling()` — Graceful degradation
  - `test_partial_install_recovery()` — Retry logic
  - `test_timeout_handling()` — Network timeout simulation
  - `test_under_five_minutes()` — Timing constraint validation
  - `test_network_failure_resilience()` — Recovery from transient failures
- Use `sw-[name]-test.sh` pattern from CLAUDE.md
- Mock external tools using temp directory
- Track pass/fail counts
- Report coverage per language

### Phase 3: Documentation (Steps 8-10)

Create design documentation and update guides.

**Step 8: Create project detection design doc**

- File: `scripts/skills/generated/project-detection-design.md`
- Content:
  - Detection signals for each language (file list, regex patterns)
  - Framework detection logic (file presence, config inspection)
  - Complexity scoring algorithm with examples
  - Edge cases and fallback behavior
  - Test cases covered

**Step 9: Create dependency installer design doc**

- File: `scripts/skills/generated/parallel-dependency-installation.md`
- Content:
  - Parallelization strategy (semaphore-based)
  - Per-tool install commands (macOS/Linux)
  - Timeout and retry logic
  - Failure recovery strategies
  - Performance characteristics

**Step 10: Create config generation design doc**

- File: `scripts/skills/generated/setup-config-generation.md`
- Content:
  - Tuning algorithm (complexity → iterations/timeouts)
  - Language-specific adjustments
  - Default values and rationale
  - Merging/idempotency guarantees
  - Example outputs for each complexity level

### Phase 4: Integration (Steps 11-12)

Integrate with existing CLI and documentation.

**Step 11: Update CLI entry point**

- File: `scripts/sw`
- Add routing for `setup-auto` subcommand
- Test that `shipwright setup-auto` works end-to-end

**Step 12: Update package.json and CLAUDE.md**

- File: `package.json`
  - Add test to npm test script: `bash scripts/sw-setup-auto-test.sh`
- File: `.claude/CLAUDE.md`
  - Add `shipwright setup-auto` to "Core Workflow" section
  - Document flags, use cases, example
  - Link to design docs

---

## Task Checklist

- [ ] **Task 1**: Create `scripts/lib/project-detector.sh` with language/framework/pm detection
- [ ] **Task 2**: Implement complexity scoring algorithm (source file count, test coverage, layers)
- [ ] **Task 3**: Create `scripts/lib/dependency-installer.sh` with parallel installation (semaphore-based)
- [ ] **Task 4**: Implement timeout and retry logic for dependency installs
- [ ] **Task 5**: Create `scripts/lib/config-generator.sh` with tuning logic
- [ ] **Task 6**: Implement idempotent merge logic (preserve existing configs)
- [ ] **Task 7**: Create `scripts/lib/agent-factory.sh` with language-specific templates
- [ ] **Task 8**: Create `scripts/sw-setup-auto.sh` orchestrator
- [ ] **Task 9**: Add `setup-auto` routing to `scripts/sw`
- [ ] **Task 10**: Create comprehensive test suite (`scripts/sw-setup-auto-test.sh`)
- [ ] **Task 11**: Implement tests for all supported languages (node/python/go/rust)
- [ ] **Task 12**: Verify timing constraint (<5 minutes with benchmarks)
- [ ] **Task 13**: Create project-detection design document
- [ ] **Task 14**: Create parallel-dependency-installation design document
- [ ] **Task 15**: Create setup-config-generation design document
- [ ] **Task 16**: Update `package.json` with test suite reference
- [ ] **Task 17**: Update `.claude/CLAUDE.md` with new command documentation
- [ ] **Task 18**: Verify idempotency (run setup twice, get same state)
- [ ] **Task 19**: Test graceful degradation (missing/slow dependencies)
- [ ] **Task 20**: Run full test suite and achieve >85% coverage

---

## Testing Approach

### Test Pyramid

**Unit Tests (70% of 100+ tests)**

- `test_detect_language_*` (5 tests) — Each language indicator
- `test_detect_framework_*` (6 tests) — Each framework type
- `test_detect_package_manager_*` (4 tests) — PM detection
- `test_complexity_scoring_*` (5 tests) — Scoring algorithm edge cases
- `test_install_check_*` (5 tests) — Check tool availability
- `test_install_command_generation_*` (6 tests) — Per-tool/OS combos
- `test_config_generation_by_complexity_*` (9 tests) — Low/med/high complexity
- `test_config_merging_*` (8 tests) — Idempotency, override behavior
- `test_agent_generation_*` (7 tests) — Template expansion per language
- `test_semaphore_parallelization_*` (4 tests) — Concurrency control
- `test_timeout_behavior_*` (3 tests) — Timeout edge cases

**Integration Tests (20% of tests)**

- `test_full_node_project_flow` — Detect → Install → Config → Agent
- `test_full_python_project_flow` — Complete flow for Python
- `test_full_go_project_flow` — Complete flow for Go
- `test_full_rust_project_flow` — Complete flow for Rust
- `test_idempotency_single_run` — Run once, verify state
- `test_idempotency_double_run` — Run twice, verify same state
- `test_missing_deps_graceful_fallback` — Tools not found, setup continues
- `test_partial_install_recovery` — Some installs fail, retry succeeds
- `test_network_timeout_resilience` — CLI install timeout, fallback
- `test_config_doctor_integration` — Config passes doctor validation

**E2E Tests (10% of tests)**

- `test_e2e_node_complete_setup` — Real Node project, real install, doctor pass
- `test_e2e_python_complete_setup` — Real Python project
- `test_e2e_timing_constraint` — Measure <5min (with margin)
- `test_e2e_multi_language_detection` — Monorepo detection fallback

### Coverage Targets

| Component           | Target | Critical Paths                           |
| ------------------- | ------ | ---------------------------------------- |
| ProjectDetector     | >90%   | Each language, framework, PM combo       |
| DependencyInstaller | >85%   | Success, timeout, retry, partial failure |
| ConfigGenerator     | >88%   | All complexity levels, idempotency       |
| AgentFactory        | >90%   | All 4 languages, non-destructive write   |
| Orchestrator        | >80%   | Full flow, error handling, reporting     |

### Critical Paths to Test

**Happy Path**:

- Detect Node.js project → Install tmux/jq/gh/claude → Generate config → Generate agents → Doctor pass → <2min

**Error Cases**:

- Missing package.json (fallback to default config)
- Network timeout during CLI install (retry, then fallback)
- Existing agent files (skip without error)
- Existing daemon-config.json (merge, preserve settings)

**Edge Cases**:

- Monorepo with mixed languages (conservatively detect)
- No test runner detected (use defaults)
- Very large project (score properly, don't timeout)
- Partial dependency install (continue with what's available)
- Root vs non-root install context

---

## Failure Mode Analysis

### Critical Failure Modes

#### 1. **Parallel Dependency Race Conditions** (Severity: Critical)

**What could go wrong**:

- Two concurrent `install_parallel()` calls for tmux could create file conflicts
- If both call `brew install tmux` simultaneously, package manager state could corrupt
- `npm install -g @anthropic-ai/claude-cli` from two processes could fight over global folder

**Root cause**:

- No locking mechanism for system package managers
- No atomicity guarantee for global installs

**Mitigation in implementation**:

1. Use exclusive lock file: `mkdir /tmp/shipwright-install-lock` (atomic on POSIX)
2. Check lock before installing: `if mkdir /tmp/shipwright-install-lock 2>/dev/null; then ...`
3. Release lock with `rmdir /tmp/shipwright-install-lock`
4. Timeout on lock acquisition (don't hang forever)
5. Test with concurrent calls in test harness

**Verification**:

- Test: `test_parallel_install_with_contention` — launch 5 concurrent installs, verify only one proceeds

---

#### 2. **Network Timeout During Claude CLI Install** (Severity: High)

**What could go wrong**:

- `npm install -g @anthropic-ai/claude-cli` requires ~100MB download
- User on slow connection (5G, satellite) could timeout after 30s default
- No fallback if Claude CLI install fails — entire setup aborts

**Root cause**:

- npm default timeout is 30s, slow network needs 2-5min
- No retry or graceful degradation for missing Claude CLI

**Mitigation in implementation**:

1. Set npm timeout to 300s: `npm install -g ... --fetch-timeout 300000`
2. Implement retry loop with exponential backoff:
   - Attempt 1: 30s timeout
   - Attempt 2: 60s timeout
   - Attempt 3: 120s timeout
3. On final failure: Log warning, continue setup (Claude CLI not critical for initial setup)
4. Check for Claude CLI at doctor stage (can warn but won't fail)

**Verification**:

- Test: `test_network_timeout_with_retry` — mock timeout on first attempt, succeed on second
- Test: `test_graceful_degradation_missing_claude` — skip Claude install, verify setup completes

---

#### 3. **Incomplete Project Detection Leading to Wrong Config** (Severity: High)

**What could go wrong**:

- Framework detection scans for `express.json` but project uses custom config file name
- Complexity scoring relies on file count but monorepo has node_modules in project root
- No `package.json` present → detector returns empty object → config gets all defaults (wrong timeouts)

**Root cause**:

- Detection logic too specific to common patterns
- node_modules directory not excluded from file count
- Missing fallback signals when primary indicators absent

**Mitigation in implementation**:

1. Use multiple detection signals, vote on result:
   - If 2/3 signals agree on framework → confidence
   - If only 1 signal → fallback to defaults + log warning
2. Exclude common directories in file count:
   - node_modules, .git, dist, build, venv, target, target/
3. Use conservative defaults when uncertain:
   - Unknown complexity → score 50 (medium)
   - Unknown test runner → use defaults for language
4. Log all detected signals for debugging

**Verification**:

- Test: `test_detection_with_minimal_project` — single package.json, verify detection works
- Test: `test_detection_of_monorepo` — monorepo structure, fallback to conservative estimate
- Test: `test_detection_logs_confidence` — log signals found and confidence level

---

#### 4. **Idempotency Broken by Merge Logic** (Severity: Medium)

**What could go wrong**:

- User runs `setup-auto` twice
- First run: creates daemon-config.json with `max_parallel: 2`
- Second run: merges new config, overwrites `max_parallel: 2` → `max_parallel: 3` (user changed it manually)
- User loses custom setting

**Root cause**:

- Merge logic doesn't preserve user modifications
- No way to distinguish user-set vs auto-generated values

**Mitigation in implementation**:

1. Preserve existing values: Only set keys that are missing, never overwrite
2. Add metadata comment: `// AUTO-GENERATED: 2026-06-11T14:00:00Z`
3. On merge: Read existing, only add missing keys
4. Document idempotency guarantee: "Safe to run multiple times"

**Verification**:

- Test: `test_idempotency_preserves_user_settings`
  - Write custom config with `max_parallel: 2`
  - Run setup-auto
  - Verify `max_parallel: 2` unchanged

---

#### 5. **Timing Constraint Failure on Slow Systems** (Severity: Medium)

**What could go wrong**:

- Dual 2-core system with 2GB RAM (e.g., free tier VPS)
- Parallel installer hits resource limits
- Each tool install takes 30s (slower than modern system)
- Total time: 45s + 45s + 40s + 35s = 165s deps alone (beyond 5min if slow doctor)

**Root cause**:

- No adaptive parallelization based on system resources
- Dependency install times vary 5-10x across systems

**Mitigation in implementation**:

1. Detect available CPU cores, cap parallel jobs:
   ```bash
   max_jobs=$(( $(nproc || echo 4) / 2 ))  # Use 50% of cores
   max_jobs=$(( max_jobs < 1 ? 1 : max_jobs ))
   ```
2. Cache installed state: Check if tools already exist first
3. Skip install if already present: tmux usually pre-installed on CI systems
4. Log timing: Print "Detected tools: tmux (cached), jq (install 15s), gh (install 20s), claude (install 30s)"
5. Warn if approaching limit: "Installing deps (est. 90s, budget 5min: ~4min 30s remaining)"

**Verification**:

- Test: `test_timing_budget_with_cached_deps` — measure time with 3/4 tools pre-installed
- Test: `test_adaptive_parallelism_on_low_core_system` — mock nproc=2, verify max_jobs=1

---

### Secondary Failure Modes

**Mode 6: Output Corruption in daemon-config.json** (Medium)

- Generated JSON could have syntax errors (unescaped quotes, trailing commas)
- Mitigation: Use `jq` for JSON generation, not string interpolation; validate with `jq empty`

**Mode 7: Agent File Permission Issues** (Low)

- .claude/agents/ directory doesn't exist or not writable
- Mitigation: Create .claude/agents/ if missing; use `install -m 644` for portability

**Mode 8: Language Detection Ambiguity** (Low)

- Project has both package.json and requirements.txt
- Mitigation: Define priority (language precedence rules), log which was chosen

---

## Alternatives Considered

### Alternative 1: Monolithic Bash Script

**Approach**: Single 1000-line `sw-setup-auto.sh` file with all logic inline  
**Pros**:

- Single entry point, no dependency injection
- Faster to write initially
- Easier to debug (linear flow)

**Cons**:

- Cannot unit test individual components (requires mocking entire script)
- Logic reuse impossible (other commands can't call detector alone)
- Maintenance nightmare as features grow
- Single bug breaks entire setup flow

**Complexity**: 30% less code initially, 300% more debugging/maintenance later  
**Verdict**: ❌ **Rejected** — violates testing and reusability principles

---

### Alternative 2: Modular Library Pattern (Selected)

**Approach**: Separate libraries for each concern, orchestrator ties together  
**Pros**:

- Each library is testable in isolation
- Logic is reusable by other commands
- Easy to extend (add new detector for new language)
- Clear separation of concerns

**Cons**:

- More files (4 libraries + CLI + tests)
- Requires clear interface contracts
- Slightly more overhead from function calls

**Complexity**: 40% more code initially, 10% less debugging/maintenance later  
**Blast radius**: Each failure isolated to one module  
**Verdict**: ✓ **Selected** — aligns with Shipwright's modular decomposition patterns

---

### Alternative 3: Python/Node.js-based Setup Tool

**Approach**: Rewrite in JavaScript/TypeScript or Python for better ecosystem  
**Pros**:

- Easier concurrent library management (async/await)
- Built-in JSON parsing, HTTP client
- Faster to write with proper stdlib

**Cons**:

- Adds runtime dependency (Node/Python)
- All Shipwright scripts must support polyglot setup
- Cannot assume Node/Python available in target project
- Harder to debug in production shell environments

**Compatibility**: Breaks Shipwright's 100% bash principle  
**Verdict**: ❌ **Rejected** — Shipwright is bash-native for portability

---

### Alternative 4: Interactive Wizard (Like `sw-setup.sh`)

**Approach**: Prompt user for choices: "Which language? Fast or thorough?"  
**Pros**:

- User explicitly approves each decision
- Educational (learns about options)

**Cons**:

- Violates "zero-config" requirement (not zero-interaction)
- Takes 10-15min with user deliberation (violates <5min budget)
- Difficult to automate in CI/unattended environments

**Use case alignment**: Good for onboarding, bad for automation  
**Verdict**: ❌ **Rejected** — `sw-setup.sh` already handles interactive case

---

### Alternative 5: Configuration File Driving Setup (`.shipwright-setup.yml`)

**Approach**: Allow `shipwright-setup.yml` in project to override defaults  
**Pros**:

- Fine-grained control for power users
- Can persist project-specific preferences
- Self-documenting (config shows what was customized)

**Cons**:

- Adds complexity (parsing YAML, schema validation)
- Still not "zero-config" if required
- Extra file to maintain per project
- Out of scope for P1 (MVP should ship without this)

**Verdict**: ❌ **Rejected for MVP** — Can be added in phase 2 if needed

---

## Definition of Done

### Acceptance Criteria

- [ ] **Detection Works**: Project detection correctly identifies node/python/go/rust projects
- [ ] **Parallel Install Works**: Dependencies installed concurrently with progress feedback
- [ ] **Config Generated**: `daemon-config.json` created with tuned parameters
- [ ] **Agents Created**: Language-specific agents generated in `.claude/agents/`
- [ ] **Idempotent**: Running setup twice produces same result, preserves user settings
- [ ] **Timing**: Complete setup in <5 minutes on standard repo (measured in test harness)
- [ ] **Validation**: `shipwright doctor` passes with no critical errors
- [ ] **Graceful Degradation**: Missing dependencies don't block setup
- [ ] **Tested**: All components have >85% coverage with unit + integration tests
- [ ] **Documented**: Design docs created for each major component
- [ ] **CLI Available**: `shipwright setup-auto` works end-to-end
- [ ] **No Regressions**: Existing `sw-setup.sh` still works unchanged

### Success Metrics

| Metric               | Target                     | Validation                             |
| -------------------- | -------------------------- | -------------------------------------- |
| Setup Time           | <5 minutes                 | Test: `test_under_five_minutes()`      |
| Detection Accuracy   | >95% for each language     | Test suite coverage per language       |
| Idempotency          | 100% (same state on rerun) | Test: run twice, diff states           |
| Test Coverage        | >85% code coverage         | `npm test` reports coverage            |
| Doctor Validation    | 100% pass rate             | All generated configs pass doctor      |
| Graceful Degradation | <30s additional delay      | Missing deps don't block, warn instead |

### Sign-Off Checklist

Before marking done:

- [ ] All 20+ tasks completed
- [ ] Test suite passes (>85% coverage)
- [ ] Timing verified <5 minutes (with realistic installs)
- [ ] Documentation complete (3 design docs + CLAUDE.md update)
- [ ] CLI integration works (`shipwright setup-auto`)
- [ ] Manual smoke test: Run on Node/Python/Go/Rust projects
- [ ] No regressions in existing setup flow
- [ ] PR ready with comprehensive test coverage

---

## Context & Constraints

### Architecture Constraints (From CLAUDE.md)

- All scripts use `set -euo pipefail`
- **Bash 3.2 compatible** — no `declare -A`, `readarray`, `${var,,}`, `${var^^}`
- Atomic writes: tmp file + mv, not `echo > file`
- JSON ops via `jq --arg`, never string interpolation
- `cd` in helpers must use subshells
- Each script has VERSION at top
- Event logging via `emit_event` for observability

### File Structure Constraints

- Libraries in `scripts/lib/` (not `src/` or `lib/`)
- Tests use `scripts/sw-*-test.sh` pattern
- CLI commands in `scripts/sw-*` pattern
- Generated docs in `scripts/skills/generated/`

### Performance Constraints

- **Time budget**: <5 minutes end-to-end
- **Concurrent processes**: Max 4 (adaptive based on cores)
- **Memory**: Single-pass streaming for large files
- **Disk**: No temporary files >100MB

### Compatibility Constraints

- macOS (10.15+) and Linux (Ubuntu 18.04+)
- No assumption Node.js installed initially
- Must work offline for GitHub detection (NO_GITHUB mode)
- Must work in minimal shell environments (Alpine, BusyBox)

---

## Git Strategy

**Branch**: Current feature branch `feat/zero-config-project-auto-setup-with-inte-629`

**Commits** (one per logical unit):

1. `feat: project detector library for multi-language detection`
2. `feat: parallel dependency installer with semaphore control`
3. `feat: config generator with complexity-based tuning`
4. `feat: agent factory with language-specific templates`
5. `feat: zero-config setup orchestrator (sw-setup-auto.sh)`
6. `test: comprehensive test suite for setup-auto`
7. `docs: setup-auto design documentation and CLAUDE.md updates`

**PR Description**: Will include:

- Screenshots of running `shipwright setup-auto` on node/python/go/rust projects
- Timing benchmarks (actual <5min measurements)
- Test coverage report (>85%)
- Before/after comparison with `sw-setup.sh` (6x faster)
