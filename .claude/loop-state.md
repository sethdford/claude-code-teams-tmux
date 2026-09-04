---
goal: "Cross-repo memory pattern query surfaced in daemon triage scoring

## Plan Summary
Plan written to `.claude/pipeline-artifacts/plan.md`.

## Key finding first

The **query half of this feature already exists and is green on this branch** — I verified before planning:

- `scripts/sw-triage.sh:314-660` — scores issue text against local `failures.json` **and** cross-repo `global.json` `.common_patterns` with a fleet penalty, config-gated under `triage.pattern_matching.*`.
- `scripts/lib/daemon-triage.sh:16-80` — `triage_score_issue()` runs the lookup, keeps its bare-integer stdout contract, and persists to `~/.shipwright/triage-pattern-matches.json`.
- `scripts/sw-triage-test.sh` (56 pass) and `scripts/sw-lib-daemon-triage-test.sh` (27 pass) both run clean.

The actual gap is the word **"surfaced"**: the match is computed and stored, then nothing consumes it. `daemon_triage_show` never mentions it, `daemon_spawn_pipeline` forwards `INTELLIGENCE_ISSUE_TYPE` but not the pattern, `sw-context.sh gather` has no section for it, no event fires on the daemon path, and the store grows unbounded.

## What the plan covers

Three consumption points plus hygiene, all additive at existing seams — no new scripts, no new state files, no change to the scoring kernel:

1. **`daemon_triage_show`** — a `Pattern` column fed by a new `triage_pattern_summary` formatter (emits only `source/score conf`, never pattern text, so the `|`-delimited row can't be corrupted).
2. **`daemon_spawn_pipeline`** — export `TRIAGE_PATTERN_MATCH` *before* `tmux new-window`, so both spawn paths inherit it.
3. **`sw-context.sh`** — `extract_known_pattern()` section (env first, store fallback, truncated to 300 chars) wired into `gather_context()`.
4. Plus `emit_event "triage.pattern_match"` and a 500-entry cap on the store.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
## Context
## Decision
### Component Diagram
### Interface Contracts
### Data Flow
### Key decisions
### Error Boundaries
## Alternatives Considered
## Implementation Plan
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Cross-repo memory pattern query surfaced in daemon triage scoring

### Goals
- Cross-repo memory pattern query surfaced in daemon triage scoring

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{"error":"memory_search_failed","results":[]}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Cross-repo memory pattern query surfaced in daemon triage scoring — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Cross-repo memory pattern query surfaced in daemon triage scoring

## Implementation Checklist
- [ ] Task 1: `emit_event "triage.pattern_match"` from the daemon lookup, guarded by `type emit_event`
- [ ] Task 2: `_triage_prune_pattern_matches` caps the store (atomic tmp+`mv`), called after every record
- [ ] Task 3: `triage_pattern_summary <issue>` one-line formatter, prints nothing on no match
- [ ] Task 4: `daemon_triage_show` gains a `Pattern` column + conditional legend
- [ ] Task 5: `daemon_spawn_pipeline` exports `TRIAGE_PATTERN_MATCH` before `tmux new-window` / subshell spawn
- [ ] Task 6: `extract_known_pattern()` section in the context bundle (env first, store fallback)
- [ ] Task 7: `sw-lib-daemon-triage-test.sh` — pruning, summary, event, integer-contract tests
- [ ] Task 8: `sw-context-test.sh` — section present / absent / corrupt-store tests
- [ ] Task 9: `.claude/CLAUDE.md` Triage Pattern Matching section documents surfacing + new key + event
- [ ] Task 10: `npm test` green; no regressions in daemon, dispatch, triage, context suites
- [ ] `shipwright daemon triage` displays source/score for issues with a stored match and is visually unchanged for issues without one
- [ ] A spawned pipeline's environment contains `TRIAGE_PATTERN_MATCH` when a match exists for that issue
- [ ] The plan/build context bundle contains a `Known Failure Pattern` section when a match exists
- [ ] `triage.pattern_match` appears in `~/.shipwright/events.jsonl` with `issue`, `source`, `score`, `confidence`
- [ ] `~/.shipwright/triage-pattern-matches.json` is capped and remains valid JSON under repeated writes
- [ ] `triage_score_issue` stdout is still a bare integer on all paths
- [ ] Every new read degrades to a no-op on missing/corrupt store, missing `jq`, or disabled config
- [ ] `npm test` passes; `shellcheck` clean on all touched scripts; bash 3.2 constructs only
- [ ] `.claude/CLAUDE.md` documents the surfacing behaviour and the new config key

## Context
- Pipeline: autonomous
- Branch: ci/issue-3996
- Issue: none
- Generated: 2026-09-04T01:10:46Z"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-09-04T01:14:44Z
last_iteration_at: 2026-09-04T01:14:44Z
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

