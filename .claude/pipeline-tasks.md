# Pipeline Tasks — Cross-repo memory pattern query surfaced in daemon triage scoring

## Implementation Checklist
- [ ] **Task 1** — Add `triage.pattern_matching` block to `config/defaults.json`; verify `_config_get "triage.pattern_matching.similarity_threshold"` returns 60 from a scratch dir.
- [ ] **Task 2** — Implement `_triage_memory_dir()` and `_triage_pattern_enabled()` in `sw-triage.sh`. *(blocks 3, 5)*
- [ ] **Task 3** — Implement `_triage_tokenize()` with the stopword list. *(blocks 4)*
- [ ] **Task 4** — Implement `triage_score_pattern()` with the 70/20/10 weights and the zero-token guard. *(depends on 3; blocks 5)*
- [ ] **Task 5** — Implement `triage_match_known_pattern()` — local `failures.json` scan, then fleet `global.json` with the -10 penalty, threshold gate, `jq -n` output. *(depends on 2, 4; blocks 6, 7)*
- [ ] **Task 6** — Convert `cmd_analyze`'s output heredoc to `jq -n` and conditionally attach `known_pattern_match`; extend `emit_event`. *(depends on 5)*
- [ ] **Task 7** — Add the `pattern-match` subcommand to `main()` and `cmd_help`. *(depends on 5; blocks 8)*
- [ ] **Task 8** — Export `TRIAGE_PATTERN_MATCH` from `triage_score_issue()` in `scripts/lib/daemon-triage.sh`, leaving the integer stdout contract intact. *(depends on 7)*
- [ ] **Task 9** — Test: fixture builder in `sw-triage-test.sh` that writes a `failures.json` + `global.json` under `MEMORY_ROOT="$TEST_TEMP_DIR/mem/<hash>"` with a deterministic git-origin mock. *(blocks 10-13)*
- [ ] **Task 10** — Test: **match** case — issue text overlapping a local pattern yields `known_pattern_match.source == "local"` and `score >= 60`.
- [ ] **Task 11** — Test: **no-match** case — unrelated issue text emits no `known_pattern_match` key, and `keys_unsorted` equals today's exact key list (AC4 backward-compat pin).
- [ ] **Task 12** — Test: **fleet** cases — global-only pattern matches with `source == "fleet"` when `fleet_enabled=true`; produces no match when `SHIPWRIGHT_TRIAGE_PATTERN_MATCHING_FLEET_ENABLED=false`.
- [ ] **Task 13** — Test: **degradation** cases — missing memory dir, corrupt `failures.json` (`{`), empty `.failures[]`, and `enabled=false` each exit 0 with no match and no stderr noise.
- [ ] **Task 14** — Bump `VERSION` to 3.4.0; update `cmd_help`; add config docs to `.claude/CLAUDE.md`.
- [ ] **Task 15** — Run `bash scripts/sw-triage-test.sh`, `bash scripts/sw-lib-daemon-triage-test.sh`, `bash scripts/sw-daemon-test.sh`, and `shellcheck scripts/sw-triage.sh`; then `npm test`.
- [ ] `shipwright triage analyze <N>` emits `known_pattern_match` (with `pattern`, `source`, `score`, `confidence`, `note`) when a memory pattern scores at or above the threshold.
- [ ] No-match output is key-for-key identical to the pre-change output — pinned by an explicit `keys_unsorted` assertion (AC4).
- [ ] Local `failures.json` is consulted first; `global.json` only when `fleet_enabled`, and a local match beats an equal-scoring fleet match.
- [ ] Missing memory dir, missing `global.json`, corrupt JSON, absent `shasum`, and `enabled=false` all no-op with exit 0 (AC2).
- [ ] `triage_score_issue()` in `daemon-triage.sh` still prints only an integer; `sw-lib-daemon-triage-test.sh` and `sw-daemon-test.sh` pass unchanged (AC4).

## Context
- Pipeline: standard
- Branch: arch/cross-repo-memory-pattern-query-surfaced-3996
- Issue: #3996
- Generated: 2026-09-03T21:57:23Z
