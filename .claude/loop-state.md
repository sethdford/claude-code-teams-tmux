---
goal: "Zero-Config Setup Wizard with Project Type Auto-Detection

## Plan Summary
# Implementation Plan: Zero-Config Setup Wizard with Project Type Auto-Detection

## Executive Summary

Shipwright already ships a robust, machine-readable project-detection library
(`scripts/lib/project-detect.sh`) covering language, framework, package manager,
test runner, test/build commands, and pipeline-template recommendation. However
the onboarding wizard (`scripts/sw-setup.sh`) **does not use it** — it re-implements
a weaker, string-only inline detector (Node/Rust/Go/Python only), never persists
detected commands into generated config, and requires interactive input (a `read`
prompt) so it cannot run truly zero-config in CI/daemon contexts.

**This feature wires the existing detection engine into the wizard, persists the
result into generated config, adds a non-interactive `--yes`/`--zero-config` path,
and fixes a cross-platform caching bug in the detection library.** It is a
reuse-and-integrate feature, not a green-field build — minimizing blast radius.

### Minimum Viable Change
Make `shipwright setup --yes` (a) detect the project via the shared library,
(b) write `test_cmd`/`build_cmd`/`pipeline_template` into `.claude/daemon-config.json`,
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Zero-Config Setup Wizard with Project Type Auto-Detection
## Context
## Decision
### Approach: Library Reuse + Opt-In Config Persistence
### 1. Fix the Detection Library's Cross-Platform Bug
### 2. Expose Detection Metadata for Wizard Display
### 3. Integrate Library into Setup Wizard
### 4. Add Non-Interactive Mode
# New flags
### 5. Persist Detection into Config
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Zero-Config Setup Wizard with Project Type Auto-Detection

### Goals
- Zero-Config Setup Wizard with Project Type Auto-Detection

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 95,
      "summary": "Contains project conventions (node, vitest, npm, commonjs) essential for auto-detecting project type in the setup wizard"
    },
    {
      "file": "success-patterns.json (0bcf0637b6e487d78af89f8cd979d6f345ceac82a47adf7d679858271d09634a)",
      "relevance": 88,
      "summary": "Feature development pattern (Add authentication, complexity 65, 3 iterations) similar in scope to setup wizard feature work"
    },
    {
      "file": "success-patterns.json (f4af3e2a8276951b3c332022c8331d835dca7f862e28fddf03541a5f168d8913)",
      "relevance": 82,
      "summary": "Build stage iteration pattern (Fix bug, complexity 60, 3 iterations, multi-file coordination) relevant to build loop execution"
    },
    {
      "file": "knowledge.json",
      "relevance": 68,
      "summary": "Captured failure patterns (mktemp issues, test setup failures) that could inform build stage execution and prevent regression"
    },
    {
      "file": "success-patterns.json (3acfa67aa7e90335958c612032342c952cb7fbdefe9a42dfb07093ffc9179a66)",
      "relevance": 65,
      "summary": "High-complexity timeout fix (3 iterations, build stage) demonstrates handling complex issues in build loop execution"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Zero-Config Setup Wizard with Project Type Auto-Detection — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Zero-Config Setup Wizard with Project Type Auto-Detection

## Implementation Checklist
- [ ] Task 1: Source `compat.sh` in `project-detect.sh`; fix `date -j` cache-age bug via `date_to_epoch`; make cache write atomic. **(blocks 3, 6)**
- [ ] Task 2: Add `project_detect_summary_line()` helper. **(blocks 3)**
- [ ] Task 3: Replace `sw-setup.sh` Phase-2 inline detector with `project_detect_all` + summary line; preserve no-detect fallback. **(needs 1, 2)**
- [ ] Task 4: Add `--yes`/`--zero-config`/`--non-interactive`/`--enable-daemon` flag parsing + `CI`/non-TTY implicit mode to `sw-setup.sh`; update `--help`.
- [ ] Task 5: Guard the daemon `read` prompt behind `NON_INTERACTIVE`. **(needs 4)**
- [ ] Task 6: Add `--from-detection <file>` to `sw-init.sh` with `jq` merge + atomic `mv`; no-op when absent. **(blocks 7)**
- [ ] Task 7: In `sw-setup.sh` Phase 3, pass `--from-detection` to `sw-init.sh`. **(needs 3, 6)**
- [ ] Task 8: Add `emit_event` calls for `setup_detected`/`setup_complete`.
- [ ] Task 9: Regression test in `sw-project-detect-test.sh` for Linux cache-age path + atomic write. **(needs 1)**
- [ ] Task 10: Extend `sw-setup-test.sh` — zero-config run completes with no prompt (`</dev/null` + timeout), detection persisted to `daemon-config.json`. **(needs 3, 5, 7)**
- [ ] Task 11: Unit test `sw-init.sh --from-detection` merges fields and is a no-op without the flag. **(needs 6)**
- [ ] Task 12: Update `.claude/CLAUDE.md`; run `shipwright version check` + `shipwright docs check`. **(needs all)**
- [ ] `shipwright setup --yes` completes with **zero interactive prompts**, exit 0, in a temp Node repo.
- [ ] Wizard detection is produced by `project-detect.sh` (inline duplicate detector removed).
- [ ] Detected `test_cmd`, `build_cmd`, and `pipeline_template` are persisted into `.claude/daemon-config.json`.
- [ ] `project-detect.sh` cache-age computation works on Linux (GNU date) — regression test passes; cache write is atomic.
- [ ] `sw-init.sh --from-detection` merges fields via `jq --arg` + atomic write, and is a no-op without the flag.
- [ ] All touched scripts remain `set -euo pipefail` and Bash 3.2 compatible.
- [ ] `emit_event` fires for `setup_detected` and `setup_complete`.
- [ ] `sw-setup-test.sh`, `sw-project-detect-test.sh`, `sw-init-test.sh` pass; `npm test` green.

## Context
- Pipeline: autonomous
- Branch: ci/issue-724
- Issue: none
- Generated: 2026-07-03T14:47:42Z"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-07-03T14:53:40Z
last_iteration_at: 2026-07-03T14:53:40Z
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

