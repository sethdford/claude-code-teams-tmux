---
goal: "Dependency Pre-Flight Check & Auto-Install Engine

## Plan Summary
I now have enough understanding of the codebase. Let me write the implementation plan.

# Implementation Plan: Dependency Pre-Flight Check & Auto-Install Engine

## Summary

Add a pre-flight stage that runs **before the build loop** (`sw loop` invocation in `stage_build()`). It detects package manifests, checks whether dependencies are installed, and auto-installs missing ones using the correct package manager. This is implemented as a **new self-contained lib module** (`scripts/lib/dependency-preflight.sh`) sourced by the build stage — honoring the architecture rule that pipeline stages source from `scripts/lib/`, never call scripts directly. Detection logic **reuses `project-detect.sh`** rather than duplicating manifest parsing.

---

## Brainstorming: Socratic Design Refinement (answered autonomously)

**Minimum viable change:** A single sourced lib module + a hook in `stage_build()` + a config flag + a test. No new CLI command, no changes to `sw-loop.sh` itself.

**Implicit requirements not stated:** (a) Must be a no-op safe failure — a failed install must **never** abort the pipeline (the build loop can still install deps itself); (b) must respect `NO_GITHUB`/offline mode (installs are local, so fine); (c) must not run in CI test harness against mock binaries (guard via config flag + `command -v` checks); (d) monorepo support — multiple manifests at depth.

**Design alternatives:**
1. **New lib module sourced by build stage (CHOSEN).** Blast radius: 1 hook line in `stage_build()` + 1 new file + config + test. Reuses `project-detect.sh`. Testable in isolation.
2. **Inline the logic directly in `stage_build()`.** Rejected — bloats an already 744-line file, violates single-responsibility, hard to unit-test.
3. **A new pipeline stage (`preflight`) between plan and build.** Rejected — over-engineered for a "fast" complexity P0; adds stage-ordering/gating surface area, touches `pipeline-stages.sh`, templates, composer. Too much blast radius for the value.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Dependency Pre-Flight Check & Auto-Install Engine
## Context
## Decision
### ⚠️ Contract correction (must fix in plan before build)
## Alternatives Considered
## Implementation Plan
## Required Architecture Sections
### Component Diagram
### Interface Contracts
### Data Flow
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Dependency Pre-Flight Check & Auto-Install Engine

### Goals
- Detect package manifest files for Node, Python, Go, Ruby, Java projects
- Parse and extract dependency lists from manifests
- Check installed status of each dependency before build loop starts
- Auto-install missing dependencies with appropriate package manager (npm, pip, go get, bundle, maven)
- Log dependency installation as pipeline event
- Skip build loop iteration 1 if all deps pre-installed
- Add daemon-config.json flag to enable/disable auto-install (default: true)
- Integration test with missing deps in test fixture
- **Priority**: P0
- **Complexity**: fast

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 95,
      "summary": "Project conventions (Node.js, vitest, npm, commonjs) directly match current build environment and test strategy"
    },
    {
      "file": "success-patterns.json",
      "relevance": 80,
      "summary": "Contains two successful patterns with iterative build/test loops, npm test strategy, and multi-iteration approaches (3-4 iterations, 45-150s duration)"
    },
    {
      "file": "failures.json",
      "relevance": 75,
      "summary": "Recent test failures (sw-cleanup.sh output format, mktemp directory issues) that could occur during transition to test stage after build completes"
    },
    {
      "file": "issues.json",
      "relevance": 65,
      "summary": "Success pattern for timeout bug fix using semaphore—directly applicable to 'Auto-Install Engine' robustness feature for dependency handling"
    },
    {
      "file": "knowledge.json",
      "relevance": 60,
      "summary": "Failure knowledge base with mktemp and test formatting issues; provides known failure signatures to avoid during build and test phases"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Dependency Pre-Flight Check & Auto-Install Engine — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Dependency Pre-Flight Check & Auto-Install Engine

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/dependency-preflight.sh` skeleton (VERSION, load guard, defensive sourcing of `project-detect.sh`/`helpers.sh`)
- [ ] Task 2: Implement `dep_detect_manifests` with bounded `find` + node_modules/vendor exclusion (monorepo-aware) *(blocks Task 3,4,5)*
- [ ] Task 3: Implement `dep_manager_available` + per-manager mapping
- [ ] Task 4: Implement `dep_is_installed` heuristics for npm/pip/go/bundle/mvn
- [ ] Task 5: Implement `dep_install` with lockfile-deterministic commands in `( cd … )` subshells *(blocked by Task 2,3)*
- [ ] Task 6: Implement `dep_preflight_run` orchestrator: config gate, loop, aggregation, `SW_DEPS_PREINSTALLED`, atomic marker write *(blocked by Task 2-5)*
- [ ] Task 7: Add `emit_event "dependencies.installed"` calls with manager/count/duration_ms/status
- [ ] Task 8: Add `_smart_bool` helper to `scripts/lib/compat.sh`
- [ ] Task 9: Hook `dep_preflight_run` into `stage_build()` (guarded, non-fatal) + source module
- [ ] Task 10: Add `dependency_preflight` block to `.claude/daemon-config.json`
- [ ] Task 11: Create `scripts/sw-lib-dependency-preflight-test.sh` with missing-deps fixtures (Node fixture w/o node_modules)
- [ ] Task 12: Add unit tests: detection (each manager), availability skip, installed-detection, disabled-flag no-op, non-fatal install failure
- [ ] Task 13: Add integration test: temp Node project with deps in package.json but no node_modules → assert install attempted + event emitted + `SW_DEPS_PREINSTALLED=0`
- [ ] Task 14: Register test in `package.json`; run full `npm test` to confirm no regressions
- [ ] Task 15: Update `.claude/CLAUDE.md` config/flag docs; bump VERSION consistency
- [ ] `dependency-preflight.sh` created; sourced by `stage_build()` behind a `type`-guard; non-fatal on all failures
- [ ] Detects package.json / requirements.txt / go.mod / Gemfile / pom.xml (Node, Python, Go, Ruby, Java)
- [ ] Checks installed status before the build loop; auto-installs missing deps with the correct manager
- [ ] Each install wrapped in `timeout` and a `( cd … )` subshell; partial/failed install never aborts pipeline
- [ ] Emits `dependencies.installed` pipeline event (manager, count, duration_ms, status) via `emit_event`

## Context
- Pipeline: standard
- Branch: ci/dependency-pre-flight-check-auto-install-637
- Issue: #637
- Generated: 2026-06-12T19:26:25Z

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: Test fixture needs real missing dependencies (not mocks) to validate skipped iteration 1; must cover monorepo detection, manifest parse failures, and manager unavailability.
- **dependency-installation-robustness**: Core skill for handling five package managers safely: manifest parsing edge cases, graceful degradation when package managers are missing, atomic install semantics, and clear observability.

## Testing Strategy Expertise

Apply these testing patterns:

### Test Pyramid
- **Unit tests** (70%): Test individual functions/methods in isolation
- **Integration tests** (20%): Test component interactions and boundaries
- **E2E tests** (10%): Test critical user flows end-to-end

### What to Test
- Happy path: the expected successful flow
- Error cases: what happens when things go wrong?
- Edge cases: empty inputs, maximum values, concurrent access
- Boundary conditions: off-by-one, empty collections, null/undefined

### Test Quality
- Each test should verify ONE behavior
- Test names should describe the expected behavior, not the implementation
- Tests should be independent — no shared mutable state between tests
- Tests should be deterministic — same result every run

### Coverage Strategy
- Aim for meaningful coverage, not 100% line coverage
- Focus coverage on business logic and error handling
- Don't test framework code or simple getters/setters
- Cover the branches, not just the lines

### Mocking Guidelines
- Mock external dependencies (APIs, databases, file system)
- Don't mock the code under test
- Use realistic test data — edge cases reveal bugs
- Verify mock interactions when the side effect IS the behavior

### Regression Testing
- Write a failing test FIRST that reproduces the bug
- Then fix the bug and verify the test passes
- Keep regression tests — they prevent the bug from recurring

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Test Pyramid Breakdown**: Explicit count of unit/integration/E2E tests and their coverage targets (e.g., "70 unit tests covering business logic, 12 integration tests for API boundaries, 3 E2E tests for critical paths")
2. **Coverage Targets**: Target coverage percentage per layer and which critical paths MUST be tested
3. **Critical Paths to Test**: Specific test cases for the happy path, 2+ error cases, and 2+ edge cases

If any section is not applicable, explicitly state why it's skipped.

## Dependency Installation Robustness

Implement a pre-flight dependency check that detects, parses, and safely installs packages across five package managers with clear error handling and observability.

### Core Challenges

**1. Manifest Detection & Parsing**
- Each language has different manifest formats: package.json (JSON), requirements.txt (plain text with comments), go.mod (TOML-like), Gemfile (Ruby DSL), pom.xml (XML).
- Parsing must be defensive—malformed manifests should report clear errors with line numbers, not crash silently.
- Support monorepo layouts where multiple manifests exist at different depths.
- Use language-native tools (node, python, go, ruby, mvn) to parse rather than regex, to handle format edge cases correctly.

**2. Package Manager Availability**
- The target package manager (npm, pip, go, bundle, maven) might not be installed.
- Failing with "command not found" is confusing—must detect upfront and provide actionable guidance (e.g., "pip not found—install Python 3").
- Verify manager version is compatible, not just present.
- This is the most common failure mode in CI environments.

**3. Installation Safety & Atomicity**
- Installing packages in the build directory can shadow system packages, cause version conflicts, or leak into production builds.
- Treat the entire install as atomic: all packages succeed, or the entire operation fails cleanly. Partial success leaves the build in an uncertain state.
- Use lockfiles (package-lock.json, poetry.lock, go.sum, Gemfile.lock) to ensure deterministic installs across environments.
- On failure, clean up any partially-installed packages so the build can retry cleanly.

**4. Error Recovery**
- Network failures during install must be distinguishable from package conflicts or broken manifests.
- Distinguish between "package manager crashed" (infrastructure issue, should retry) and "manifest is invalid" (code issue, should fail).
- Log root cause analysis: Was it a missing package manager? Malformed manifest? Version conflict? Network timeout?

**5. Observability for the Pipeline**
- The build loop needs to know what was installed, why it took time, and whether to skip iteration 1.
- Emit pipeline events: `type=dependencies_installed manager=npm count=42 duration_ms=5230 status=success`.
- Log individual install commands and their output so debugging is possible.
- Track which manifests were found and processed.
[... skills truncated: 9549→8000 chars ...]

**Safe Installation**
- Use `npm ci` (clean install from lockfile) instead of `npm install` (allows upgrades).
- Use `pip install -r requirements.txt` with `--prefer-offline` to avoid unexpected changes.
- Use `go mod download` before `go mod verify` to validate checksums.
- Use `bundle install --no-deployment` (or `--deployment` if Gemfile.lock exists) for Ruby.
- Use `mvn dependency:resolve` to download without compiling.

**Atomic Installation**
```bash
# Create temp directory, install there, verify success, move to real location
temp_dir=$(mktemp -d)
trap "rm -rf '$temp_dir'" EXIT

if npm ci --prefix "$temp_dir" 2>&1 | tee "$temp_dir/install.log"; then
  mv "$temp_dir/node_modules" "./node_modules"
  success "Installed $(jq -r '.dependencies | keys | length' package.json) npm dependencies"
else
  error "npm install failed: $(tail -5 "$temp_dir/install.log")"
  exit 1
fi
```

**Logging & Observability**
```bash
# Log manifest detection
info "Found Node.js manifest: package.json ($(jq -r '.dependencies | keys | length' package.json) deps)"

# Log installation start
start=$(date +%s%N)

# Run install
npm ci 2>&1 | tee install.log

# Log completion
duration=$(( ($(date +%s%N) - start) / 1000000 ))
emit_event "dependencies_installed" \
  "manager=npm" "count=42" "duration_ms=$duration" "status=success"
```

### Edge Cases to Handle

1. **Monorepo with multiple manifests**: Should you install all, or only root? Design: install root first, then any other top-level manifests.
2. **Lockfile without manifest** (or vice versa): Warn but don't fail—let the build discover the real error.
3. **Broken package manager** (installed but crashes): Distinguish from missing manager. Both should skip gracefully.
4. **Network failure mid-install**: Retry up to 2 times with exponential backoff. If persistent, fail clearly.
5. **Dependency conflicts** (two manifests want incompatible versions): Log the conflict, let the build fail later with a clear error.
6. **Disk space exhaustion**: Check available disk before installing. Fail with "Disk full" rather than cryptic install errors.
7. **Pre-existing partial installations**: Clean up before installing to avoid version conflicts.

### Testing Strategy

**Unit Tests**
- Manifest parsing: valid, malformed, missing required fields, edge cases (empty files, BOM markers).
- Manager detection: installed, missing, broken (crashes on --version).
- Error message generation: clear, actionable, language-appropriate.

**Integration Tests**
- End-to-end with real npm, pip, go, bundle, mvn on test fixtures.
- Test fixtures with intentionally missing dependencies.
- Verify iteration 1 is skipped when all deps are pre-installed.
- Test monorepo scenarios with multiple manifests.
- Test network failure recovery (mock network timeouts).
- Test disk space handling (mock df to report low space).

**Fault Injection**
- Remove package managers mid-install (simulate uninstall during build).
- Truncate manifests to test parse error handling.
- Fill disk to test exhaustion scenarios.
- Introduce version conflicts in lock files.

### Configuration

Add to `daemon-config.json`:
```json
{
  "dependency_preflight": {
    "enabled": true,
    "managers": ["npm", "pip", "go", "bundle", "maven"],
    "skip_on_error": false,
    "max_install_time_seconds": 300
  }
}
```

Allow pipeline stage to override: `--dependency-install-timeout 600`.
"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-06-12T19:47:55Z
last_iteration_at: 2026-06-12T19:47:55Z
consecutive_failures: 0
total_commits: 1
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

