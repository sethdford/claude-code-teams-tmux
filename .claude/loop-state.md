---
goal: "Automated Tech Stack Example Repository Generator for Adoption Showcase

## Plan Summary
# Implementation Plan: Automated Tech Stack Example Repository Generator for Adoption Showcase

**Issue:** #441
**Stage:** plan
**Complexity:** simple
**Date:** 2026-05-07

## Goal

Add a new Shipwright command that generates a minimal tech-stack example repository (scaffold) demonstrating Shipwright adoption for a target stack (Node, Python, Go). The artifact is a directory of files that a new user can copy/clone to see Shipwright integrated into a representative project.

## Socratic Refinement (Self-Answered)

### Requirements Clarity
- **Minimum viable change:** A single new bash module `scripts/sw-showcase.sh` plus CLI router wiring that, given `--stack <node|python|go>` and `--out <dir>`, writes a reproducible scaffold (README, sample source file, sample test, `.claude/CLAUDE.md` stub, and a `daemon-config.json`).
- **Implicit requirements:** Idempotent regeneration, atomic writes, `NO_GITHUB`-safe (purely local), no destructive overwrite without `--force`.
- **Acceptance criteria (defined since none provided):**
  1. `shipwright showcase --stack node --out /tmp/x` exits 0 and produces a directory with at least: `README.md`, `package.json`, `src/index.js`, `test/index.test.js`, `.claude/CLAUDE.md`, `.claude/daemon-config.json`.
  2. The same command refuses to overwrite an existing non-empty `--out` unless `--force` is passed.
  3. `shipwright showcase --stack python --out X` produces analogous Python scaffold (`pyproject.toml`, `src/`, `tests/`).
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Automated Tech Stack Example Repository Generator for Adoption Showcase
## Context
## Decision
### Component Diagram
### Interface Contracts
# Public entry point (invoked by router)
# Internal contracts (in script scope)
### Data Flow
### Error Boundaries
## Alternatives Considered
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Automated Tech Stack Example Repository Generator for Adoption Showcase

### Goals
- Automated Tech Stack Example Repository Generator for Adoption Showcase

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json (sethdford/shipwright, 2026-05-03)",
      "relevance": 95,
      "summary": "Exact repo configuration: Node project, vitest test runner, npm package manager, commonjs imports, src/ source dir. Directly applicable to current build stage."
    },
    {
      "file": "success-patterns.json (auth module feature)",
      "relevance": 85,
      "summary": "Feature implementation in Node with complexity 60, TDD approach, unit+integration tests, 5 iterations. Directly relevant pattern for building new features in this project type."
    },
    {
      "file": "failures.json (ENOENT missing dependency)",
      "relevance": 80,
      "summary": "Critical build-stage failure: missing npm install. Shows 95% fix effectiveness. Highly relevant for preventing common npm-based build failures."
    },
    {
      "file": "success-patterns.json (bug fixes, iterations 3)",
      "relevance": 60,
      "summary": "Shows successful iteration and audit cleanup patterns for this repo. Demonstrates post-audit cleanup approach and loop-state management relevant to build stage recovery."
    },
    {
      "file": "failures.json (cannot read property)",
      "relevance": 50,
      "summary": "Common Node.js initialization bug with 100% fix effectiveness. Useful reference pattern for debugging runtime errors that may occur during build."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Automated Tech Stack Example Repository Generator for Adoption Showcase — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Automated Tech Stack Example Repository Generator for Adoption Showcase

## Implementation Checklist
- [ ] Task 1: Create `scripts/sw-showcase.sh` skeleton (shebang, pipefail, VERSION, usage)
- [ ] Task 2: Implement argument parsing with validation
- [ ] Task 3: Implement pre-flight + force-overwrite guard
- [ ] Task 4: Implement Node stack writer (atomic, jq-built JSON)
- [ ] Task 5: Implement Python stack writer
- [ ] Task 6: Implement Go stack writer
- [ ] Task 7: Implement common file writer (.claude/, README, .gitignore)
- [ ] Task 8: Add `emit_event` and success summary
- [ ] Task 9: Wire `showcase` subcommand into `scripts/sw` router
- [ ] Task 10: Create `scripts/sw-showcase-test.sh` with ≥6 PASS/FAIL cases
- [ ] Task 11: Register test in `package.json` test chain
- [ ] Task 12: Run `npm test` locally, fix regressions
- [ ] Task 13: Run `shipwright docs sync` to update AUTO sections
- [ ] `shipwright showcase --help` prints usage
- [ ] `shipwright showcase --stack node --out /tmp/sw-demo` writes ≥6 files
- [ ] Generated `package.json` parses with `jq`
- [ ] Refuses overwrite without `--force`; honors `--force`
- [ ] All three stacks (node, python, go) supported
- [ ] `scripts/sw-showcase-test.sh` passes with PASS=N, FAIL=0
- [ ] `npm test` exits 0

## Context
- Pipeline: autonomous
- Branch: ci/issue-441
- Issue: none
- Generated: 2026-05-07T20:52:07Z"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-05-07T21:05:07Z
last_iteration_at: 2026-05-07T21:05:07Z
consecutive_failures: 0
total_commits: 2
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

