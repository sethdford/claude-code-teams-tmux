---
goal: "Community Starter Kit Generator with Framework Detection and Best-Practice Templates

## Plan Summary
The implementation plan has been written to `.claude/pipeline-artifacts/plan.md`.

**Summary of the plan:**

**Approach:** New `shipwright starter-kit` command (alias `sk`) backed by `lib/starter-kit.sh` library — zero risk to existing `sw-prep.sh`.

**3 new files, 2 modified:**
- `scripts/lib/starter-kit.sh` — Framework-specific best practices, quality checks, pitfalls, and example issue generators for Node.js, Python, Go, Rust, Ruby (~450 lines)
- `scripts/sw-starter-kit.sh` — CLI with `generate`, `issues`, `check`, `help` subcommands (~350 lines)
- `scripts/sw-starter-kit-test.sh` — Test suite covering all 5 frameworks + edge cases (~400 lines)
- `scripts/sw` — Add `starter-kit|sk` route (2 lines)
- `package.json` — Register test in chain (1 line)

**Key design decisions:**
- Reuses existing `lib/project-detect.sh` for detection (already works for 8+ languages)
- Uses `<!-- sw:starter-kit-start/end -->` markers for idempotent CLAUDE.md enhancement
- Generates 3-5 example issue templates in `.github/ISSUE_TEMPLATE/` (universal + framework-specific)
- Validates type/framework combinations to handle detection edge cases gracefully
- Atomic file writes throughout; `--dry-run` flag for safe CI usage
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Community Starter Kit Generator with Framework Detection and Best-Practice Templates
## Context
## Decision
### Component Diagram
### Data Flow
### Interface Contracts
### Error Boundaries
### Framework Dispatch Design
## Alternatives Considered
### 1. Modify `sw-prep.sh` directly
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Contains build-stage failures for JavaScript variable initialization (undefined properties, undeclared variables) with 100% and 66% fix effectiveness. Directly applicable to detecting and fixing common errors during generator build phase."
    },
    {
      "file": "failures.json",
      "relevance": 90,
      "summary": "ENOENT failure pattern for missing npm dependencies with 95% fix effectiveness. Critical for build stage—generator likely needs dependency installation before tests/build."
    },
    {
      "file": "success-patterns.json",
      "relevance": 75,
      "summary": "Feature work patterns from sethdford/shipwright showing 3-4 iteration counts, npm test strategy, standard template, and file change patterns for framework-related work. Patterns model for building starter kit generator feature."
    },
    {
      "file": "patterns.json",
      "relevance": 70,
      "summary": "Shipwright repo metadata: Node.js project with vitest test runner, npm package manager, commonjs imports. Provides exact build environment configuration and conventions for testing during build stage."
    },
    {
      "file": "patterns.json",
      "relevance": 65,
      "summary": "Bootstrap detection shows nodejs project type. Confirms framework detection patterns are appropriate for Node.js environment and helps understand how detection should work."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Community Starter Kit Generator with Framework Detection and Best-Practice Templates — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Community Starter Kit Generator with Framework Detection and Best-Practice Templates

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/starter-kit.sh` with framework best practices lookup functions (Node.js, Python, Go, Rust, Ruby) — Tasks 2-4 depend on this
- [ ] Task 2: Add quality checks functions to `lib/starter-kit.sh` returning JSON per framework
- [ ] Task 3: Add example issue generation functions to `lib/starter-kit.sh`
- [ ] Task 4: Add pitfalls/gotchas functions per framework to `lib/starter-kit.sh`
- [ ] Task 5: Create `scripts/sw-starter-kit.sh` CLI with `generate`, `issues`, `check`, `help` subcommands — depends on Tasks 1-4
- [ ] Task 6: Implement `generate` subcommand — auto-detect → prep → enhance CLAUDE.md → quality checks → issues → report
- [ ] Task 7: Implement `issues` subcommand — generate example issue templates only
- [ ] Task 8: Implement `check` subcommand — audit existing starter kit setup
- [ ] Task 9: Add `starter-kit|sk` route to `scripts/sw` CLI router
- [ ] Task 10: Create `scripts/sw-starter-kit-test.sh` with tests for all 5 frameworks + edge cases
- [ ] Task 11: Register test in `package.json` test chain
- [ ] Task 12: Run full test suite to verify no regressions
- [ ] `shipwright starter-kit generate` works end-to-end for Node.js, Python, Go, Rust, Ruby projects
- [ ] CLAUDE.md is enhanced with framework-specific conventions, pitfalls, and quality guidance
- [ ] 3-5 example issue templates generated per project in `.github/ISSUE_TEMPLATE/`
- [ ] Quality checks JSON generated with framework-appropriate commands
- [ ] `shipwright starter-kit check` reports setup completeness
- [ ] All new tests pass (`scripts/sw-starter-kit-test.sh`)
- [ ] Full test suite passes (`npm test`) — no regressions
- [ ] CLI router updated — `shipwright starter-kit` and `shipwright sk` work

## Context
- Pipeline: standard
- Branch: feat/community-starter-kit-generator-with-fra-349
- Issue: #349
- Generated: 2026-04-03T18:34:18Z

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **framework-detection-best-practices**: Implement robust file-based detection for Go, Python, Node, Rust, etc. with fallback strategies and confidence scoring; detection failures directly break the user experience.

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
"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-04-03T18:47:12Z
last_iteration_at: 2026-04-03T18:47:12Z
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

