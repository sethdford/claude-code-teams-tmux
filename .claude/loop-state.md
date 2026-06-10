---
goal: "Fallback Policy Migrator — Convert 67 Static Fallbacks to Config-Driven Adaptive Overrides

## Plan Summary
# Implementation Plan — Fallback Policy Migrator: Convert 67 Static Fallbacks to Config-Driven Adaptive Overrides

## Current State (grounding the plan)

The **fallback-policy *infrastructure* already exists** on this branch (`ci/issue-620`):

| Component | Path | Status |
|-----------|------|--------|
| Resolver (`_smart_fallback`, `_fallback_clamp`, `_fallback_audit`) | `scripts/lib/fallback-policy.sh` | ✅ Built (171 lines) |
| Policy config | `config/fallback-policy.json` | ⚠️ Only **20** policies declared |
| JSON schema | `config/fallback-policy.schema.json` | ✅ Built |
| CLI (`audit`/`inventory`/`list`/`get`/`validate`) | `scripts/sw-fallback.sh` | ✅ Built, wired into `scripts/sw` router (l.614) |
| Unit test | `scripts/sw-fallback-policy-test.sh` | ✅ Registered in `package.json` |
| Docs | `.claude/CLAUDE.md` "Fallback Policy System" | ✅ Written |

**The gap:** `grep -rn _smart_fallback scripts/ --include='*.sh'` (excluding the lib + test) finds the resolver invoked at exactly **one** call-site — `sw-fallback.sh:97`, which is the CLI's own `get` command. **Zero production call-sites have actually been migrated.** The 20 declared policies are inert.

**Therefore the goal "Convert 67 Static Fallbacks" is the migration work itself**, in two parts:
1. **Expand** `config/fallback-policy.json` from 20 → ~67 declared policies (the high-impact runtime fallbacks).
2. **Rewire** ~67 real `${VAR:-N}` call-sites to resolve through `_smart_fallback "key" N`, keeping `N` as the fail-safe argument so behavior is byte-identical until config/learning changes it.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Fallback Policy Migrator — Convert 67 Static Fallbacks to Config-Driven Adaptive Overrides
## Context
## Decision
### Component Diagram
### Interface Contracts
### Data Flow
### Error Boundaries
## Alternatives Considered
## Implementation Plan
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Fallback Policy Migrator — Convert 67 Static Fallbacks to Config-Driven Adaptive Overrides

### Goals
- Fallback Policy Migrator — Convert 67 Static Fallbacks to Config-Driven Adaptive Overrides

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json (sethdford/shipwright, 2026-06-10)",
      "relevance": 95,
      "summary": "Current repo with exact project structure: Node.js, vitest, npm, commonjs imports. Captured today. Essential context for build toolchain decisions."
    },
    {
      "file": "knowledge.json",
      "relevance": 88,
      "summary": "Recent test failure patterns (mktemp, sw-cleanup output formatting). These failures are relevant to build/test stage and show common pitfalls in this codebase."
    },
    {
      "file": "failures.json (sw-cleanup.sh, 2026-06-10)",
      "relevance": 82,
      "summary": "Current test stage failure about heartbeat detection and output formatting. Captured today, directly applicable to build/test phases of this pipeline."
    },
    {
      "file": "metrics.json",
      "relevance": 65,
      "summary": "Baseline build duration of 2089s provides iteration budget estimate and helps set realistic expectations for 20-iteration build loop."
    },
    {
      "file": "success-patterns.json (bug fix, 2026-03-29)",
      "relevance": 58,
      "summary": "Similar bug fix pattern with 3 iterations and scripts/lib work. Shows successful iterative approach on config/infrastructure changes similar to fallback policy migration."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Fallback Policy Migrator — Convert 67 Static Fallbacks to Config-Driven Adaptive Overrides — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Fallback Policy Migrator — Convert 67 Static Fallbacks to Config-Driven Adaptive Overrides

## Implementation Checklist
- [ ] Task 1: Inventory + filter to the canonical 67 high-impact sites; reconcile vs. existing 20
- [ ] Task 2: Define var→key namespace map (one key per semantic fallback)
- [ ] Task 3: Expand `config/fallback-policy.json` to ~67 entries (`static == literal`)
- [ ] Task 4: `fallback validate` + `jq empty` green on expanded config
- [ ] Task 5: Migrate `loop.*` call-sites + `sw-loop-test.sh`
- [ ] Task 6: Migrate `pipeline.*` call-sites + pipeline lib tests
- [ ] Task 7: Migrate `daemon.*`/`patrol.*` call-sites + `sw-daemon-test.sh`
- [ ] Task 8: Migrate `stall.*`/`recovery.*` call-sites + tests
- [ ] Task 9: Migrate `network.*` call-sites
- [ ] Task 10: Migrate `review.*`/`simulation.*`/`cleanup.*` call-sites
- [ ] Task 11: Extend `sw-fallback-policy-test.sh` (count, range, fail-safe, behavior-preservation)
- [ ] Task 12: Update `.claude/CLAUDE.md`; run `fallback audit`
- [ ] Task 13: Full `npm test` green
- [ ] Task 14: `VERSION` header bumps + `shipwright version check`
- [ ] `config/fallback-policy.json` declares **≥ 67** policies; `shipwright fallback validate` exits 0.
- [ ] **≥ 67** production call-sites resolve through `_smart_fallback` (verified by `grep -c`, excluding the CLI self-reference).
- [ ] Every migrated `static` equals its original call-site literal (behavior-preservation tests pass).
- [ ] `shipwright fallback audit scripts` reports `declared ≥ 67`.
- [ ] Deleting `config/fallback-policy.json` restores pre-migration behavior (fail-safe test passes).
- [ ] `sw-fallback-policy-test.sh` extended and green; full `npm test` green.

## Context
- Pipeline: autonomous
- Branch: ci/issue-620
- Issue: none
- Generated: 2026-06-10T20:59:35Z"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-06-10T21:40:56Z
last_iteration_at: 2026-06-10T21:40:56Z
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

