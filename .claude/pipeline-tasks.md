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
- Generated: 2026-09-04T01:10:46Z
