---
goal: "Script Complexity Doctor Check with Refactor Suggestions

## Plan Summary
I'll analyze this task systematically and create a detailed implementation plan for the Script Complexity Doctor Check feature.

## Socratic Analysis

### Requirements Clarity

**What is the minimum viable change?**
A command that analyzes shell scripts in the `scripts/` directory, measuring complexity metrics (cyclomatic complexity, lines of code, nesting depth, function count), identifying violations of the "Common Pitfalls" documented in CLAUDE.md, and suggesting specific refactors.

**Implicit requirements** (from context):
- Should integrate into existing `shipwright doctor` command (already at 1635 lines)
- Should flag violations of Bash 3.2 compatibility rules documented in the project
- Should analyze all 100+ existing scripts and provide prioritized refactor suggestions
- Should follow project conventions: `set -euo pipefail`, atomic writes, jq escaping, etc.
- Should provide both standalone CLI access and integration into doctor checks

**Acceptance criteria** (defined from issue context):
1. CLI command: `shipwright complexity [<script>|--all|--recursive <dir>]`
2. Identifies 5+ anti-patterns from Common Pitfalls section of CLAUDE.md
3. Calculates metrics: LOC, cyclomatic complexity, nesting depth, function count
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Script Complexity Doctor Check with Refactor Suggestions
## Context
## Decision
### Component Diagram
### Data Flow
### Interface Contracts
### Error Boundaries
### Anti-Pattern Detection Rules (8 rules from CLAUDE.md Common Pitfalls)
### Caching Strategy
## Alternatives Considered
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Contains 21-5 occurrences of script failures with root causes and fixes (sw-cleanup.sh, sw-feedback-test.sh, sw-hello-test.sh, sw-code-review-test.sh). Critical for identifying complexity issues and refactoring targets in the codebase."
    },
    {
      "file": "patterns.json (first entry with conventions)",
      "relevance": 75,
      "summary": "Provides project structure: Node.js, vitest, npm, CommonJS imports, src/ source dir. Understanding project conventions is essential context for refactoring suggestions."
    },
    {
      "file": "patterns.json (second entry - bootstrap)",
      "relevance": 50,
      "summary": "Confirms project_type as nodejs detected at bootstrap. Provides baseline project context, less detailed than first patterns entry."
    },
    {
      "file": "metrics.json",
      "relevance": 15,
      "summary": "Contains empty baselines object. Minimal relevance; would be useful if populated with complexity metrics or performance baselines."
    },
    {
      "file": "patterns.json (third entry - empty patterns)",
      "relevance": 10,
      "summary": "Empty patterns array with minimal metadata. No actionable insights for script complexity analysis or refactoring."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Script Complexity Doctor Check with Refactor Suggestions — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Script Complexity Doctor Check with Refactor Suggestions

## Implementation Checklist
- [ ] `scripts/lib/complexity-analyzer.sh` created and unit tested
- [ ] `scripts/sw-complexity.sh` CLI command working with --all, --recursive, --json flags
- [ ] Can analyze all 100+ scripts without errors
- [ ] Identifies 5+ distinct anti-patterns from Common Pitfalls
- [ ] Detects and flags 10+ scripts with refactor opportunities
- [ ] Doctor integration shows complexity section without breaking other checks
- [ ] JSON report matches schema (script, metrics, complexity, violations)
- [ ] Performance acceptable: `--all` completes in <30 seconds (with caching)
- [ ] Test suite covers unit + integration cases, all passing
- [ ] Manual verification of top 5 recommendations are sound
- [ ] Documentation updated: CLAUDE.md AUTO section + CLI help
- [ ] No regressions in existing doctor functionality

## Context
- Pipeline: autonomous
- Branch: ci/issue-272
- Issue: none
- Generated: 2026-03-14T20:07:19Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-14T20:12:43Z
last_iteration_at: 2026-03-14T20:12:43Z
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

