# Tasks — Meta-Feature Development Pattern Library with Build Loop Context Injection

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-233

## Checklist
- [ ] Task 1: Create `scripts/lib/feature-patterns.sh` with module guard, init, storage schema, and fallback helpers
- [ ] Task 2: Implement `featpat_classify_type()` — keyword-based feature type classification (Bash 3.2 safe)
- [ ] Task 3: Implement `featpat_capture()` — extract pattern from pipeline state file + git diff, deduplicate, atomic write
- [ ] Task 4: Implement `featpat_match()` — score and rank stored patterns against a goal using jq
- [ ] Task 5: Implement `featpat_inject()` — format matched patterns as markdown for prompt injection (2K char cap)
- [ ] Task 6: Implement `featpat_show()` and `featpat_prune()` — CLI display and maintenance
- [ ] Task 7: Implement `featpat_record_helpfulness()` — effectiveness tracking
- [ ] Task 8: Integrate module sourcing and capture hook into `sw-memory.sh` (source lib, hook into `memory_capture_pipeline`, add CLI subcommand, update `ensure_memory_dir`)
- [ ] Task 9: Integrate pattern injection into `lib/loop-iteration.sh` `compose_prompt()` — add feature_patterns_section variable and prompt heredoc section
- [ ] Task 10: Add feature patterns to `manage_context_window()` progressive trim order
- [ ] Task 11: Create `scripts/sw-feature-patterns-test.sh` with 15 test cases
- [ ] Task 12: Register test suite in `package.json`
- [ ] Task 13: Run full test suite — verify no regressions in existing tests
- [ ] `scripts/lib/feature-patterns.sh` exists with all 8 functions (init, classify, capture, match, inject, show, prune, record_helpfulness)
- [ ] Feature patterns are automatically captured after successful pipeline runs (hooked into `memory_capture_pipeline`)
- [ ] Feature type classification works for all 8 types (api, cli, ui, refactor, bugfix, infra, test, docs) + generic fallback
- [ ] Pattern matching returns relevant results ranked by type match + keyword similarity + recency + outcome
- [ ] Build loop prompt includes "Similar Feature Development Patterns" section when matches exist
- [ ] Context window trimming includes feature patterns in the progressive trim order
- [ ] `shipwright memory patterns` displays captured patterns with goal, type, iterations, outcome

## Notes
- Generated from pipeline plan at 2026-03-08T12:54:49Z
- Pipeline will update status as tasks complete
