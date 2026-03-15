# Implementation Plan: Complete Test Coverage for 3 Untested Core Scripts

**Goal**: Add test suites for sw-tmux-role-color.sh, sw-tmux-status.sh, and sw-tracker-github.sh to move test coverage from 97% to 100%.

**Acceptance Criteria**:
- [ ] Test suite exists for sw-tmux-role-color.sh with ≥3 test cases
- [ ] Test suite exists for sw-tmux-status.sh with ≥3 test cases
- [ ] Test suite exists for sw-tracker-github.sh with ≥5 test cases
- [ ] All new tests pass in CI
- [ ] Test coverage metric updates to 100% (103/103 scripts)

---

## Test Pyramid Breakdown

### sw-tmux-role-color.sh (81 lines)
- **Unit Tests (8 tests)**: Role keyword mapping to colors
  - Default color (cyan) when no match
  - Leader/PM → cyan
  - Builder/dev → blue
  - Reviewer → orange
  - Tester → yellow
  - Security → red
  - Docs/writer → violet
  - Optimizer → green
  - Researcher → purple
  - Case-insensitive matching
  - Empty/null title fallback
- **Integration Tests (2 tests)**: tmux interaction
  - Calls `tmux display-message` to read pane_title
  - Calls `tmux set` to update border color

**Coverage Target**: 100% of role matching logic, tmux interaction paths

---

### sw-tmux-status.sh (152 lines)
- **Unit Tests (8 tests)**: Color/icon mappings, stage detection
  - stage_color() returns correct color for each of 12 stages
  - stage_color() fallback for unknown stage
  - stage_icon() returns correct icon for each of 12 stages
  - stage_icon() fallback for unknown stage
  - Extraction of stage from state file via grep + sed
  - Uppercase conversion for label display
- **Integration Tests (4 tests)**: Widget dispatch and rendering
  - pipeline_widget() extracts stage from state file and outputs tmux format string
  - agent_widget() counts active heartbeats (< 60 seconds old)
  - Dispatch with "pipeline" argument
  - Dispatch with "agents" argument
  - Dispatch with "all" argument combines both widgets

**Coverage Target**: 100% of stage detection, all color/icon mappings, all dispatch paths

---

### sw-tracker-github.sh (213 lines)
- **Unit Tests (10 tests)**: GitHub API wrapper functions
  - discover_issues() returns JSON array with correct schema {id, title, labels[], state}
  - discover_issues() respects label filter
  - discover_issues() respects state filter
  - discover_issues() respects limit parameter
  - get_issue() returns normalized issue JSON
  - get_issue() returns error (exit 1) on missing issue_id
  - add_label() calls gh with correct arguments
  - remove_label() calls gh with correct arguments
  - comment() creates comment on issue
  - close_issue() closes issue
  - create_issue() creates issue and extracts issue number from response
  - create_issue() handles comma-separated labels
  - create_issue() handles space-separated labels
  - get_issue_body() returns plain text body
- **Error Path Tests (3 tests)**: NO_GITHUB guard and fallbacks
  - discover_issues() returns [] when NO_GITHUB=1
  - get_issue() returns 0 (no-op) when NO_GITHUB=1
  - provider_notify() logs event even when NO_GITHUB=1

**Coverage Target**: 100% of provider_* functions, all $NO_GITHUB guards, JSON normalization

---

## Critical Paths to Test

### sw-tmux-role-color.sh
1. **Happy Path**: pane_title="builder-agent" → PANE_TITLE extracted → COLOR="#0066ff" set
2. **Fallback Path**: pane_title="unknown-xyz" → COLOR defaults to "#00d4ff" (cyan)
3. **Empty Input**: pane_title="" → COLOR defaults to cyan
4. **Case Insensitivity**: pane_title="Builder-Agent" matches "builder" pattern
5. **No tmux Available**: tmux display-message fails → PANE_TITLE="" → defaults to cyan

### sw-tmux-status.sh
1. **Happy Path**: .claude/pipeline-state.md exists with "Stage: build" → outputs build badge with blue color and ⚙ icon
2. **Missing State File**: No state file → pipeline_widget returns empty (return 0)
3. **Stage Extraction**: Extract "build" from various formats: "Stage: build", "**Stage:** build", "Current Stage: build"
4. **All 12 Stages**: Each stage (intake, plan, design, build, test, review, compound_quality, pr, merge, deploy, validate, monitor) maps to correct color/icon
5. **Agent Count**: 5 fresh heartbeats (< 60s old) → outputs "λ5" badge
6. **Mixed Freshness**: 3 fresh + 2 stale heartbeats → outputs "λ3" (only fresh counted)
7. **Dispatch**: "all" argument combines pipeline + agents widgets

### sw-tracker-github.sh
1. **Happy Path**: gh discover_issues returns JSON → normalized to {id, title, labels[], state}
2. **Label Filter**: gh called with --label shipwright → only issues with that label returned
3. **State Filter**: gh discover_issues --state closed → returns closed issues only
4. **NO_GITHUB Guard**: NO_GITHUB=1 → all functions return 0 (no-op) silently
5. **gh Command Failure**: gh fails (exit 1) → returns fallback [] or error code
6. **Issue Creation**: gh create response "Created issue owner/repo#123" → extracts number 123
7. **Multi-Label Create**: labels="shipwright,test" → calls gh with multiple --label flags
8. **Empty Body Handling**: provider_comment() with empty body → returns error (exit 1)

---

## Files to Modify

### New Files to Create:
- `/home/runner/work/shipwright/shipwright/scripts/sw-tmux-role-color-test.sh` (~120 lines)
- `/home/runner/work/shipwright/shipwright/scripts/sw-tmux-status-test.sh` (~180 lines)
- `/home/runner/work/shipwright/shipwright/scripts/sw-tracker-github-test.sh` (~200 lines)

### Files to Update:
- `/home/runner/work/shipwright/shipwright/package.json` - Add 3 new test suites to "test" script (in alphabetical order: after `sw-tmux-pipeline-test.sh`, before `sw-tmux-test.sh`, etc.)

---

## Implementation Steps

### Phase 1: Create sw-tmux-role-color-test.sh

1. **Boilerplate**: Add header comment, set -euo pipefail, source test-helpers.sh
2. **Setup**: Create setup_env() that:
   - Creates temp directory for scripts
   - Copies sw-tmux-role-color.sh
   - Creates mock tmux binary that returns configurable PANE_TITLE via MOCK_TMUX_PANE_TITLE env var
   - Sets SCRIPT_DIR override to test scripts
3. **Cleanup**: Add cleanup_env() that removes temp directory, trap on EXIT
4. **Test Helpers**: Define assert_role_color(title, expected_color) helper
5. **Tests** (10 total):
   - test_default_color_when_no_match()
   - test_leader_role_cyan()
   - test_builder_role_blue()
   - test_reviewer_role_orange()
   - test_tester_role_yellow()
   - test_security_role_red()
   - test_docs_role_violet()
   - test_optimizer_role_green()
   - test_researcher_role_purple()
   - test_case_insensitive_matching()
   - test_empty_title_defaults_to_cyan()
6. **Results**: Print PASS/FAIL summary, exit 0 if all pass, 1 if any fail

### Phase 2: Create sw-tmux-status-test.sh

1. **Boilerplate**: Header, set -euo pipefail, source test-helpers.sh
2. **Setup**: Create setup_env() that:
   - Creates temp directory with scripts/lib structure
   - Copies sw-tmux-status.sh and lib files
   - Creates fake .claude/pipeline-state.md with "Stage: build"
   - Creates fake ~/.shipwright/heartbeats/ with 5 test files
   - Creates mock tmux, gh, curl binaries
   - Mock stat/date for mtime checks
3. **Source Script**: Load sw-tmux-status.sh (it contains functions, not a main)
4. **Tests** (15 total):
   - For stage_color():
     - test_stage_color_intake() → #71717a
     - test_stage_color_plan() → #7c3aed
     - test_stage_color_build() → #0066ff
     - test_stage_color_deploy() → #4ade80
     - test_stage_color_unknown() → #71717a (fallback)
   - For stage_icon():
     - test_stage_icon_intake() → ◇
     - test_stage_icon_build() → ⚙
     - test_stage_icon_test() → ⚡
     - test_stage_icon_unknown() → · (fallback)
   - For pipeline_widget():
     - test_pipeline_widget_extracts_stage()
     - test_pipeline_widget_missing_state_file()
     - test_pipeline_widget_outputs_tmux_format()
   - For agent_widget():
     - test_agent_widget_counts_fresh_heartbeats()
     - test_agent_widget_ignores_stale_heartbeats()
     - test_agent_widget_no_heartbeats()
   - For dispatch:
     - test_dispatch_pipeline_argument()
     - test_dispatch_agents_argument()
     - test_dispatch_all_argument()
5. **Results**: Print summary, exit with appropriate code

### Phase 3: Create sw-tracker-github-test.sh

1. **Boilerplate**: Header, set -euo pipefail, source test-helpers.sh
2. **Setup**: Create setup_env() that:
   - Creates temp directory with scripts structure
   - Copies sw-tracker-github.sh and lib files
   - Creates mock gh binary that returns canned JSON responses via MOCK_GH_RESPONSE env var
   - Creates mock jq (or uses real jq)
   - Override SCRIPT_DIR
3. **Source Script**: Source sw-tracker-github.sh to load provider_* functions
4. **Tests** (18 total):
   - For discover_issues():
     - test_discover_issues_returns_json_array()
     - test_discover_issues_respects_label_filter()
     - test_discover_issues_respects_state_filter()
     - test_discover_issues_respects_limit()
     - test_discover_issues_no_github_returns_empty()
     - test_discover_issues_gh_failure_returns_empty()
   - For get_issue():
     - test_get_issue_returns_normalized_json()
     - test_get_issue_missing_id_exits_1()
     - test_get_issue_no_github_returns_0()
   - For get_issue_body():
     - test_get_issue_body_returns_text()
     - test_get_issue_body_no_github_returns_0()
   - For add_label():
     - test_add_label_calls_gh()
     - test_add_label_no_github_returns_0()
   - For remove_label():
     - test_remove_label_calls_gh()
     - test_remove_label_no_github_returns_0()
   - For comment():
     - test_comment_creates_issue_comment()
     - test_comment_empty_body_fails()
   - For close_issue():
     - test_close_issue_closes_issue()
   - For create_issue():
     - test_create_issue_extracts_number()
     - test_create_issue_comma_separated_labels()
     - test_create_issue_space_separated_labels()
     - test_create_issue_no_labels()
   - For provider_notify():
     - test_provider_notify_logs_event()
5. **Results**: Print summary, exit appropriately

### Phase 4: Update package.json Test Script

1. **Location**: "scripts"."test" field in package.json
2. **Changes**:
   - Add `bash scripts/sw-tmux-role-color-test.sh` (after sw-tracker-test.sh)
   - Add `bash scripts/sw-tmux-status-test.sh` (after sw-tmux-role-color-test.sh)
   - Add `bash scripts/sw-tracker-github-test.sh` (before sw-tmux-pipeline-test.sh for alphabetical order)
3. **Order**: Scripts should be in alphabetical order within the test chain

### Phase 5: Verification

1. **Run New Tests Individually**:
   ```bash
   bash scripts/sw-tmux-role-color-test.sh
   bash scripts/sw-tmux-status-test.sh
   bash scripts/sw-tracker-github-test.sh
   ```
2. **Run Full Test Suite**: `npm test` (should pass all 103+ tests)
3. **Check Coverage**: Verify no untested scripts remain in scripts/ directory

---

## Task Checklist

- [ ] Create sw-tmux-role-color-test.sh with 10 test cases
- [ ] Create sw-tmux-status-test.sh with 15 test cases
- [ ] Create sw-tracker-github-test.sh with 18 test cases
- [ ] Update package.json test script to add 3 new test suites
- [ ] Run individual test: sw-tmux-role-color-test.sh → passes
- [ ] Run individual test: sw-tmux-status-test.sh → passes
- [ ] Run individual test: sw-tracker-github-test.sh → passes
- [ ] Run full test suite: npm test → all tests pass
- [ ] Verify no regressions in existing tests
- [ ] Verify coverage is now 100% (103 scripts tested)

---

## Testing Approach

### Unit Test Validation
- Each test function is independent (no shared state)
- Test names describe expected behavior (e.g., `test_builder_role_blue` not `test_color_mapping`)
- Assertions use clear before/after descriptions
- Use assert_eq/assert_contains/assert_pass/assert_fail from test-helpers.sh

### Mock Environment Strategy
- Temp directory isolated per test run
- Mock binaries have configurable behavior via env vars (MOCK_*)
- Real external tools (jq) are passed through if available
- NO_GITHUB env var fully guarded in provider tests

### Error Path Testing
- Test missing files (state file for pipeline_widget)
- Test command failures (gh exits with error)
- Test guards (NO_GITHUB=1 silences all GitHub calls)
- Test empty inputs (empty pane_title, empty labels, etc.)

### Integration Point Testing
- Test tmux interaction (mock display-message, verify set call)
- Test GitHub API normalization (verify JSON schema matches)
- Test dispatch routing (all three dispatch modes: pipeline, agents, all)

### Coverage Metrics
- **sw-tmux-role-color.sh**: 100% line coverage expected (10 tests cover all case branches)
- **sw-tmux-status.sh**: 100% line coverage expected (15 tests cover all functions, dispatch paths)
- **sw-tracker-github.sh**: 100% line coverage expected (18 tests cover all 9 provider_* functions + guards)

---

## Definition of Done

✅ **Code Quality**:
- [ ] All scripts pass shellcheck with no warnings
- [ ] All scripts use set -euo pipefail
- [ ] All scripts follow existing naming conventions
- [ ] All helper functions are well-commented

✅ **Test Completeness**:
- [ ] Minimum 10 tests for sw-tmux-role-color.sh
- [ ] Minimum 15 tests for sw-tmux-status.sh
- [ ] Minimum 18 tests for sw-tracker-github.sh
- [ ] All critical paths tested (happy, error, edge cases)
- [ ] All test cases pass

✅ **Integration**:
- [ ] package.json updated with 3 new test suites
- [ ] Tests run in CI with npm test
- [ ] No existing tests regress
- [ ] Coverage metric shows 100% (103/103 scripts)

✅ **Acceptance Criteria Met**:
- [ ] Test suite exists for sw-tmux-role-color.sh with ≥3 test cases ✓
- [ ] Test suite exists for sw-tmux-status.sh with ≥3 test cases ✓
- [ ] Test suite exists for sw-tracker-github.sh with ≥5 test cases ✓
- [ ] All new tests pass in CI ✓
- [ ] Test coverage metric updates to 100% (103/103 scripts) ✓

---

## Failure Mode Analysis

### Runtime Failures

**Failure Mode 1**: tmux binary not in PATH during testing
- **What Could Break**: sw-tmux-role-color.sh calls `tmux display-message` which fails silently with `2>/dev/null || echo ""`
- **Impact**: PANE_TITLE becomes empty, falls back to default color (cyan)
- **Mitigation**: Mock tmux binary in test PATH; verify fallback behavior with mock returning empty
- **Test Case**: test_no_tmux_available()

**Failure Mode 2**: gh command failure in provider functions
- **What Could Break**: discover_issues() calls `gh "${gh_args[@]}"` which returns non-zero, then echoes "[]"
- **Impact**: Empty response returned instead of actual issues, but gracefully handled
- **Mitigation**: Mock gh to simulate failure; verify fallback return value "[]"
- **Test Case**: test_discover_issues_gh_failure_returns_empty()

**Failure Mode 3**: State file malformed or missing required "Stage:" line
- **What Could Break**: pipeline_widget() extracts stage with grep/sed; if stage is empty, widget returns 0 (no output)
- **Impact**: No status displayed, which is correct behavior
- **Mitigation**: Test with various state file formats; verify extraction logic
- **Test Case**: test_pipeline_widget_missing_stage_line()

### Concurrency Risks

**Failure Mode 4**: Heartbeat file mtime check with clock skew
- **What Could Break**: agent_widget() compares `now - mtime < 60` seconds; system clock jump could cause false positives
- **Impact**: Fresh heartbeat counted as stale or vice versa
- **Mitigation**: Mock `date +%s` and `stat` to return controlled timestamps; test boundary conditions
- **Test Case**: test_agent_widget_exactly_60_seconds_old_is_stale()

**Failure Mode 5**: Multiple JSON parsing failures in jq
- **What Could Break**: normalization uses `jq '[.[] | {id: .number, ...}]'` which fails on malformed JSON
- **Impact**: Returns empty array if jq fails (due to `|| echo "[]"`)
- **Mitigation**: Mock jq to return malformed JSON; verify fallback
- **Test Case**: test_discover_issues_jq_failure_returns_empty()

### Scale Risks

**Failure Mode 6**: Hundreds of heartbeat files
- **What Could Break**: agent_widget() loops `for hb in "$hb_dir"/*.json` which becomes slow with 1000+ files
- **Impact**: Widget blocks tmux status refresh for seconds
- **Mitigation**: Test with 100 mock heartbeat files; verify execution completes in <100ms
- **Test Case**: test_agent_widget_scales_with_100_heartbeats()

**Failure Mode 7**: Large state file with multiple "Stage:" lines
- **What Could Break**: pipeline_widget() extracts stage with `grep ... | head -1` which handles this correctly, but large file read is slow
- **Impact**: Minor latency in status display
- **Mitigation**: Test with 10MB state file; verify grep + sed completes quickly
- **Test Case**: test_pipeline_widget_large_state_file()

**Most Critical**: **Failure Mode 1 (tmux unavailable)** and **Failure Mode 2 (gh failure)**
- Both are common in CI/test environments
- Both are handled with graceful fallbacks in the code
- Tests must verify fallbacks work (PANE_TITLE="", gh returns "[]")

### Rollback Story

- **Data Migration Risk**: None — these are stateless utility scripts with no persistent state
- **Revert Strategy**: Simply delete the three test files and revert package.json changes
- **No Breaking Changes**: New tests don't modify behavior of tested scripts
- **Safe to Revert**: `git checkout -- scripts/sw-*-test.sh package.json`

---

## Alternatives Considered

### Alternative 1: Minimal Testing (3 tests each = 9 total)
**Approach**: Write bare-minimum tests (1 happy path, 1 error, 1 edge case per script)

**Trade-offs**:
- ❌ Doesn't test all color mappings in sw-tmux-status.sh (only 1 happy path)
- ❌ Doesn't cover all 9 provider functions in sw-tracker-github.sh
- ❌ Doesn't test edge cases like multi-label handling
- ❌ Coverage appears 100% but misses important branches
- ✅ Faster to write (3 hours vs 8 hours)
- ✅ Fewer potential test failures

**Rejection**: Too low coverage quality; fails spirit of "meaningful test coverage"

### Alternative 2: TypeScript/JavaScript Rewrite
**Approach**: Rewrite the three scripts in TypeScript with Jest tests

**Trade-offs**:
- ✅ Cleaner syntax, better IDE support
- ✅ Can use more sophisticated test libraries
- ❌ Requires tmux runtime to be shimmed (not just mocked)
- ❌ tmux color codes won't match real behavior
- ❌ GitHub API needs full GraphQL client
- ❌ Breaks bash-only philosophy of Shipwright
- ❌ Major risk of regressions

**Rejection**: Out of scope; these are bash scripts for a reason

### Alternative 3: Integration Tests Only (no unit tests)
**Approach**: Test scripts end-to-end with real tmux, real gh, real files

**Trade-offs**:
- ✅ Tests real behavior
- ✅ Catches integration issues immediately
- ❌ Requires tmux to be installed in CI
- ❌ Requires GitHub credentials or complex stubs
- ❌ Tests are slow (seconds per test)
- ❌ Flaky due to external dependencies
- ❌ Hard to test error paths (can't easily kill tmux)

**Rejection**: Unit tests with mocks are more reliable and faster

### Chosen Approach: Unit Tests with Mocks
**Why It's Best**:
- ✅ Fast (all tests run in <1 second)
- ✅ Reliable (no external dependencies)
- ✅ Comprehensive (test happy path + error paths + edge cases)
- ✅ Follows existing Shipwright test patterns
- ✅ Can be added to CI without extra setup
- ✅ Easy to test error conditions (force gh to fail, etc.)

---

## Context Engineering Notes

**Token Efficiency**:
- Used Glob to find existing test patterns instead of reading 100+ test files
- Read only necessary sections of large test files (limit=150, 200)
- Batch-read 3 scripts in parallel to understand testing requirements
- Avoided reading all 103 existing tests; sampled representative patterns

**Compression-Ready**:
- Plan is self-contained and doesn't require prior conversation context
- Each test file is independent (can be written in any order)
- package.json update is a simple find-and-replace
- Can resume from any phase if context resets

