# Pipeline Tasks — Build Loop Test Output Intelligent Summarization and Failure Prioritization

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/loop-test-summarizer.sh` with module guard, VERSION, and core functions (`summarize_test_output`, `_extract_error_blocks`, `_categorize_error`, `_cluster_errors`, `_prioritize_clusters`, `_generate_focused_prompt`)
- [ ] Task 2: Implement error extraction that handles multi-line stack traces and multiple test frameworks
- [ ] Task 3: Implement categorization logic (syntax/type/assertion/integration/runtime/unknown)
- [ ] Task 4: Implement clustering by file path and normalized error pattern
- [ ] Task 5: Implement priority scoring and sorting
- [ ] Task 6: Implement focused prompt generation with top 3-5 clusters and remainder count
- [ ] Task 7: Write JSON output with atomic file writes (tmp + mv)
- [ ] Task 8: Source `loop-test-summarizer.sh` in `sw-loop.sh` and call after `write_error_summary()`
- [ ] Task 9: Modify `compose_prompt()` in `loop-iteration.sh` to prefer intelligent summary with fallback
- [ ] Task 10: Create test suite `scripts/sw-loop-test-summarizer-test.sh` with mock test output for 10/50/100 error scenarios
- [ ] Task 11: Register test suite in `package.json`
- [ ] Task 12: Add documentation to CLAUDE.md under Build Loop Capabilities
- [ ] Task 13: Run test suite and verify all tests pass
- [ ] `scripts/lib/loop-test-summarizer.sh` exists with all 6 core functions
- [ ] Categorizes failures into syntax/type/assertion/integration/runtime/unknown
- [ ] Clusters related failures (same file, same pattern) — "5 auth failures" not 5 separate
- [ ] Prioritizes by impact: syntax > runtime > type > integration > assertion
- [ ] Generates focused prompt with top 3-5 clusters and suggested fix order
- [ ] Integrated in `sw-loop.sh` after `write_error_summary()`
- [ ] Integrated in `compose_prompt()` with graceful fallback to existing behavior

## Context
- Pipeline: standard
- Branch: feat/build-loop-test-output-intelligent-summa-275
- Issue: #275
- Generated: 2026-03-15T08:27:41Z
