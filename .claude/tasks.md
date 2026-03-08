# Tasks — Meta-Feature Development Pattern Library with Build Loop Context Injection

## Status: In Progress
Pipeline: standard | Branch: feat/meta-feature-development-pattern-library-233

## Checklist
- [ ] Task 1: Create `scripts/lib/loop-patterns.sh` with `detect_dev_pattern()`, `inject_pattern_guidance()`, and `list_dev_patterns()`
- [ ] Task 2: Create `docs/patterns/dev/README.md` index file
- [ ] Task 3: Create `docs/patterns/dev/new-command.md` pattern
- [ ] Task 4: Create `docs/patterns/dev/test-suite.md` pattern
- [ ] Task 5: Create `docs/patterns/dev/library-module.md` pattern
- [ ] Task 6: Create `docs/patterns/dev/intelligence-module.md` pattern
- [ ] Task 7: Create `docs/patterns/dev/pipeline-stage.md` pattern
- [ ] Task 8: Create `docs/patterns/dev/build-loop-feature.md` pattern
- [ ] Task 9: Create `docs/patterns/dev/github-integration.md`, `agent-definition.md`, `daemon-feature.md`, `hook.md` patterns
- [ ] Task 10: Integrate pattern injection into `compose_prompt()` in `scripts/lib/loop-iteration.sh`
- [ ] Task 11: Add pattern trimming to `manage_context_window()` in `scripts/lib/loop-iteration.sh`
- [ ] Task 12: Update `.claude/agents/pipeline-agent.md` with pattern library reference
- [ ] Task 13: Update `.claude/CLAUDE.md` with Development Patterns section
- [ ] Task 14: Create `scripts/sw-pattern-library-test.sh` test suite
- [ ] Task 15: Register test suite in `package.json` and verify all tests pass
- [ ] All 10 pattern files exist in `docs/patterns/dev/` with required sections
- [ ] `detect_dev_pattern()` correctly classifies 10 known goal strings (one per pattern)
- [ ] `inject_pattern_guidance()` returns formatted markdown for matching goals, empty for non-matching
- [ ] `compose_prompt()` includes `## Development Pattern Guidance` section when patterns match
- [ ] `manage_context_window()` can trim pattern section when context budget is tight

## Notes
- Generated from pipeline plan at 2026-03-08T12:40:45Z
- Pipeline will update status as tasks complete
