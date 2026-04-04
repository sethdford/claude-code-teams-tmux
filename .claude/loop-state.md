---
goal: "Community Starter Kit Generator with Framework Detection and Best-Practice Templates

## Plan Summary
I'll provide the detailed implementation plan directly in my response:

---

## **Community Starter Kit Generator — Implementation Plan**

### **Overview**

This plan extends `sw-prep.sh` with zero-touch framework detection and best-practice generation, reducing initial setup time from **10 minutes → 2 minutes** per project. The generator auto-creates CLAUDE.md starter templates, recommends pipeline configurations, and generates example GitHub issues.

---

## **Requirements Analysis & Design Rationale**

### **Minimum Viable Change**

- Add `--gen-starter-kit` flag to `shipwright prep` 
- Generate three artifacts:
  1. **CLAUDE-starter.md** — framework-aware best-practice configuration
  2. **starter-issues.json** — 5 templated GitHub issues (dependency update, bug fix, feature, docs, tests)
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Community Starter Kit Generator
## Context
## Decision
### Architecture Overview
### Component Decomposition
### Why Monolithic (Not Separate Module)
## Alternatives Considered
### 1. **Separate `sw-starter-kit.sh` Module**
### 2. **Interactive Wizard (`--interactive` flag)**
### 3. **External API (Cloud Service)**
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 75,
      "summary": "Node.js project detection with vitest, npm, commonjs conventions. Directly applicable to framework detection aspect of the starter kit generator."
    },
    {
      "file": "failures.json",
      "relevance": 70,
      "summary": "Build stage failures for variable initialization and reference errors. Highly relevant patterns for catching common JavaScript/build errors in generated projects."
    },
    {
      "file": "patterns.json",
      "relevance": 70,
      "summary": "Node.js project type detection from bootstrap. Core framework detection capability needed for the starter kit generator."
    },
    {
      "file": "success-patterns.json",
      "relevance": 65,
      "summary": "Successful build patterns using npm test and standard template across 3-4 iterations. Shows effective test strategy and build loop behavior for nodejs projects."
    },
    {
      "file": "failures.json",
      "relevance": 60,
      "summary": "ENOENT/missing dependency errors with npm install fix. Relevant for ensuring starter kit projects have proper dependency installation in build stage."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Community Starter Kit Generator with Framework Detection and Best-Practice Templates — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Community Starter Kit Generator with Framework Detection and Best-Practice Templates

## Implementation Checklist
- [ ] **Task 1**: Implement `prep_detect_repo_size()` function
- [ ] **Task 2**: Implement `recommend_pipeline_template()` function
- [ ] **Task 3**: Create framework pattern library (`scripts/templates/framework-patterns.json`)
- [ ] **Task 4**: Implement `generate_claudemd()` function
- [ ] **Task 5**: Create framework template files
- [ ] **Task 6**: Implement `validate_starter_kit()` function
- [ ] **Task 7**: Implement `generate_github_issues()` function
- [ ] **Task 8**: Implement `generate_labels_config()` function
- [ ] **Task 9**: Add `--gen-starter-kit` flag to sw-prep.sh CLI
- [ ] **Task 10**: Implement summary output function
- [ ] **Task 11**: Create `scripts/sw-prep-starter-kit-test.sh` unit test suite
- [ ] **Task 12**: Integration test for 3 representative projects
- [ ] **Task 13**: Register test in `package.json`
- [ ] **Task 14**: Create `docs/starter-kit-guide.md`
- [ ] **Task 15**: Update `.claude/CLAUDE.md` with new command docs

## Context
- Pipeline: standard
- Branch: feat/community-starter-kit-generator-with-fra-349
- Issue: #349
- Generated: 2026-04-04T01:18:48Z

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **framework-detection-best-practices**: Framework detection is the reliability linchpin—poor detection cascades to broken generated configs, making this the highest-ROI focus area for both design and build.
- **testing-strategy**: Detection logic with 5+ frameworks and mono-repo edge cases demands exhaustive test matrix (happy path per framework, conflicts, missing files, corrupted files).

## Framework Detection Best Practices

Framework detection is the foundation of zero-touch config generation. Poor detection means generated configs fail, destroying user trust at the critical onboarding moment.

### Detection Strategy

**Tier 1: Primary Markers (High Confidence)**
- Language-specific manifests: `go.mod`, `package.json`, `pyproject.toml`, `Cargo.toml`, `pom.xml`, `build.gradle`
- Parse and validate content (never assume format without verification)
- Single manifest = reliable detection

**Tier 2: Secondary Markers (Medium Confidence)**
- CI/CD configs: `.github/workflows/*.yml`, `.gitlab-ci.yml`, `azure-pipelines.yml` (reveal test frameworks, build patterns)
- Build scripts: `Makefile`, `build.sh`, `Justfile`, `tox.ini` (expose test tooling)
- Tool configs: `.eslintrc.json`, `.pylintrc`, `clippy.toml` (indicate linting/quality tools)

**Tier 3: Fallback (Low Confidence)**
- Source file extensions: `*.go`, `*.py`, `*.rs`, `*.ts` (only if no manifest found)
- Treat as "best guess" and include confidence in output

### Edge Cases & Handling

**Monorepos**
- Scan all directories for manifests, not just root
- Return structured result: `{root: Generic, workspaces: [{path: "api", framework: "Go"}, {path: "web", framework: "Node"}]}`
- Generate per-workspace configs or unified multi-workspace config

**Hybrid Stacks**
- Multiple manifests = prioritize by specificity (manifest > CI config > build script)
- Return primary + secondaries: primary used for config, secondaries inform cross-framework recommendations

**Minimal/Atypical Projects**
- No manifest found? Ask user or default to generic template
- Include confidence score in result: `{framework: "unknown", confidence: 0.0, detected: [], recommendation: "Please specify framework"}`

### Implementation Checklist

- [ ] Parse manifests correctly (Go mods are text, JSON must validate, Python requires ast, TOML is strict format)
- [ ] Fixture tests: 5+ real projects per framework (minimal, standard, monorepo, outdated versions, atypical layout)
- [ ] Integration tests: generate config for fixture → run setup → verify no errors
- [ ] Edge case tests: missing files, multi-framework, no CI, renamed manifests
- [ ] Confidence scoring: return `{framework, confidence: 0.0-1.0}` so caller can decide if prompting needed
- [ ] Document detection logic per framework (what files = what conclusion)

### Testing Framework Fixture Examples

**Go:** `go.mod` with `go` directive, `go.sum`, `cmd/main.go`
**Python:** `pyproject.toml` with `[project]` section, `requirements.txt`, `setup.py`
**Node:** `package.json` with `{"type": "module"}` or `{"engines": {"node"}}`, `npm-shrinkwrap.json`
**Rust:** `Cargo.toml` with `[package]`, `Cargo.lock`, `src/main.rs` or `src/lib.rs`

### Avoid

- Magic strings: don't hardcode "lodash" or "pytest" checks—parse dependency sections correctly
- Ignoring nested projects: monorepos have multiple manifests at different depths
- Assuming framework without validation: check that manifest actually parses
- Overconfidence: if detection is ambiguous, say so

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
"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-04-04T01:23:15Z
last_iteration_at: 2026-04-04T01:23:15Z
consecutive_failures: 0
total_commits: 0
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

