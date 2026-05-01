# Post-Merge Branch Validation and Auto-Revert System — Implementation Plan

**Issue**: #430  
**Goal**: Post-Merge Branch Validation and Auto-Revert System  
**Status**: Plan (in progress)  
**Complexity**: fast/standard  
**Date**: 2026-05-01

---

## Executive Summary

This feature adds a safety net for production merges by validating that the main branch remains green after a merge completes. If validation fails, the system automatically reverts the commit and reopens the issue with failure context. The implementation uses a state machine for atomicity, Checks API for CI polling, and memory logging to capture failure patterns.

### Key Design Decision

Rather than creating a separate post-merge validation stage, **enhance the existing `validate` stage** to work as a post-merge gate. The validate stage runs after the merge stage completes, polling GitHub Checks and running smoke tests. If validation fails within a 15-minute window, auto-revert is triggered.

**Rationale**:

- Reuses existing `stage_validate()` infrastructure
- Leverages established state management patterns
- Minimizes blast radius (changes contained to one stage)
- Can be skipped via pipeline config (enabled by default for standard/full templates)

---

## Requirements Analysis

### Stated Acceptance Criteria

✅ Runs after merge stage completes successfully  
✅ Executes smoke test suite (configurable, defaults to quick validation subset)  
✅ Polls GitHub Checks API for required status checks on merge commit  
✅ Auto-reverts merge commit if validation fails within 15 minutes  
✅ Reopens original issue with label "validation-failed" and failure details  
✅ Logs validation outcome to memory (patterns of what breaks main)  
✅ Skippable via pipeline template flag (enabled by default for full/standard)

### Implicit Requirements (Derived)

- **Idempotency**: Revert can fail; ensure reverted commit is not reverted twice
- **Distributed state**: New commits may land during 15-min validation window; don't revert old commit if HEAD has moved
- **Graceful degradation**: If Checks API times out, assume validation PASSED (fail-open)
- **Async recovery**: If issue reopening fails, queue it for retry (don't silently fail)
- **Memory learning**: Track commit SHAs, test failures, and revert outcomes for pattern detection

---

## Alternatives Considered

### Alternative 1: Separate post-merge-validate Stage (Rejected)

**Approach**: Insert new `post-merge-validate` stage after merge in pipeline config.

**Pros**:

- Clear separation of concerns
- Can be toggled independently

**Cons**:

- Requires modifying all 9 pipeline templates
- Adds complexity to stage orchestration
- Redundant with existing validate stage
- Higher blast radius (more files to change)

**Trade-off**: More explicit but duplicates infrastructure.

### Alternative 2: External monitoring job (Rejected)

**Approach**: Run validation as a separate daemon job watching main branch post-merge.

**Pros**:

- Decoupled from pipeline
- Can continuously monitor

**Cons**:

- Hard to tie back to original issue
- Timing window becomes fuzzy
- Requires daemon + state sync infrastructure

**Trade-off**: Loses issue context and deterministic failure attribution.

### Chosen Approach: Enhance Existing Validate Stage (Selected)

- Reuse `stage_validate()` in `pipeline-stages-monitor.sh`
- Add post-merge-specific logic (Checks API polling, auto-revert)
- Add config flags to enable/disable auto-revert behavior
- Log outcomes to memory system
- Support graceful timeout handling

**Rationale**: Minimal changes, maximum reuse, clear failure path, easy to test.

---

## Failure Mode Analysis

### 1. Revert Merge Conflict (Critical)

**Scenario**: `git revert <commit>` fails because the revert cannot be cleanly applied (later commits have modified the same lines).

**Impact**: Validation fails but merge is NOT reverted. Main branch is left in a potentially broken state. Issue is NOT reopened.

**Mitigation**:

- Detect revert failure by checking exit code
- If revert fails, write failure to `.claude/pipeline-artifacts/revert-failed.json`
- Create a HIGH-PRIORITY incident issue instead of auto-reopening (requires manual intervention)
- Log with event type `merge.validation.revert_conflict` for operator awareness
- Implement backoff: don't attempt revert if 3+ reverts failed in past 24 hours

### 2. Checks API Timeout (Medium)

**Scenario**: GitHub Checks API takes longer than 180s to complete required checks (network latency, GitHub's eventual consistency).

**Impact**: Validation logic times out and assumes success (fail-open), potentially missing real failures.

**Mitigation**:

- Poll with exponential backoff (1s → 2s → 4s → 8s up to 180s)
- Document fail-open behavior: "Better to merge a regression than lock main"
- Fallback: If API is unreachable, assume success after retries
- Store all Checks API responses in `.claude/pipeline-artifacts/checks-responses.jsonl` for post-hoc analysis
- Alert operator if Checks API times out more than once per day

### 3. Cascading Reverts (High)

**Scenario**: New commit lands on main (commit N+1) after validation starts on commit N. Commit N's validation fails and reverts. Then commit N+1's validation also fails and attempts to revert, creating 2 revert commits.

**Impact**: Confusing commit history, potential state corruption, team confusion about what's actually reverted.

**Mitigation**:

- **Commit SHA lockfile**: Store validation state with the SHA being validated
- **No-cascade rule**: If `git log --oneline | head -1` SHA != validation state SHA, skip revert
- Check: "Let N+1's validation handle its own revert"
- Log with event `merge.validation.skipped_revert_newer_commit` for transparency

### 4. State File Corruption (High)

**Scenario**: Write to `.claude/pipeline-artifacts/validation-state.json` fails partway through (disk full, permission denied). File is left in corrupted JSON state.

**Impact**: Next validation attempt fails to parse state, potential retry loops or skipped validation.

**Mitigation**:

- **Atomic writes**: Write to temp file, sync, then mv (never direct echo > file)
- Validate JSON before assuming it's valid: `jq . validation-state.json >/dev/null || echo "corrupt"`
- On corruption, reset state to `STATE_VALIDATING` and restart
- Pre-allocate disk space check before starting validation

### 5. Issue Reopening Fails (Medium)

**Scenario**: After successful revert, `gh issue reopen` fails (issue deleted, repository archived, rate-limited).

**Impact**: Merge is reverted but team doesn't know—issue stays closed. Information loss about what failed.

**Mitigation**:

- **Async retry queue**: If reopening fails, write to `.claude/pipeline-artifacts/pending-issue-reopens.jsonl`
- Circuit breaker: If issue reopening fails 3 times in a row for the same issue, alert operator and stop retrying
- Store failure reason: `{"issue_num": 123, "failed_at": "2026-05-01T12:30:00Z", "reason": "404", "commit_sha": "abc123"}`
- Next validation run processes the backlog

### 6. Race Condition: Simultaneous Validations (Medium)

**Scenario**: Two commits land on main quickly. Both start validation stages in parallel, both attempt to revert different commits.

**Impact**: Non-deterministic state, potential both-revert or neither-revert outcomes.

**Mitigation**:

- **Flock-based locking**: Use `flock -x` on `.claude/pipeline-artifacts/validation-lock` to serialize validations
- Timeout: If validation lock is held for >30 min, break it (assume prior process died)
- Log every lock acquisition/release: `merge.validation.lock_acquired`, `merge.validation.lock_released`

---

## Proposed Solution

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    PIPELINE FLOW                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  [merge stage]                                                   │
│       ↓                                                          │
│  [validate stage] ← ENHANCED                                    │
│    1. Acquire lock                                             │
│    2. Write state: STATE_VALIDATING                            │
│    3. Poll Checks API (with timeout)                           │
│    4. Run smoke tests                                          │
│    5. On success: STATE_SUCCESS → complete                     │
│    6. On failure: STATE_FAILED                                 │
│           ↓                                                     │
│    7. Check if HEAD has moved (no-cascade)                     │
│    8. Attempt git revert → STATE_REVERTING                     │
│    9. Verify revert (check SHA diff)                           │
│    10. STATE_REVERTED → reopen issue → complete                │
│           ↓ (on revert failure)                                │
│    11. STATE_REVERT_FAILED → create incident issue → alert     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

State File: .claude/pipeline-artifacts/validation-state.json
{
  "state": "STATE_VALIDATING|STATE_SUCCESS|STATE_FAILED|STATE_REVERTING|STATE_REVERTED|STATE_REVERT_FAILED",
  "merge_commit_sha": "abc123",
  "validation_start_epoch": 1234567890,
  "checks_api_responses": [...],
  "smoke_tests_log": "...",
  "revert_status": {"success": true|false, "sha_after": "xyz789"}
}
```

### Key Components

1. **Validation State Machine** (`pipeline-stages-monitor.sh` enhancement)
   - Track state atomically in JSON file
   - Transitions: VALIDATING → {SUCCESS | FAILED} → {REVERTING → REVERTED | REVERT_FAILED}

2. **Checks API Poller** (uses `sw-github-checks.sh`)
   - Query required checks for merge commit SHA
   - Retry with exponential backoff (1s → 2s → 4s → 8s)
   - Timeout: 180s (3 min) → fail-open (assume success)
   - Store all responses in `checks-responses.jsonl`

3. **Safe Revert Logic** (new helper in `lib/pipeline-merge-validation.sh`)
   - Idempotency: Check if commit already reverted via `git log --grep="Revert"`
   - No-cascade: Compare HEAD SHA against validation state commit SHA
   - Atomic revert: Create revert commit, verify SHA changed, push if configured

4. **Issue Reopening with Context** (new helper)
   - Use `gh issue reopen` + comment with failure summary
   - Attach label: `validation-failed`
   - Include: merge commit SHA, test failure details, revert commit SHA
   - Async retry queue if initial attempt fails

5. **Memory Logging** (use existing memory system)
   - Endpoint: `~/.shipwright/memory/<repo-hash>/validation-failures.jsonl`
   - Per-entry: commit SHA, test failed, time to detection, revert outcome, root cause category
   - Used by predictive/intelligence modules to flag high-risk commits

6. **Configuration** (pipeline template enhancement)
   - Add to validate stage config:
     ```json
     {
       "id": "validate",
       "enabled": true,
       "config": {
         "smoke_cmd": "npm test -- --testPathPattern=smoke",
         "health_url": "",
         "close_issue": true,
         "post_merge_validation": true,
         "post_merge_smoke_cmd": "npm test -- --testPathPattern=smoke",
         "auto_revert": true,
         "revert_timeout_min": 15,
         "checks_poll_timeout_s": 180,
         "require_approved_checks": true
       }
     }
     ```

---

## Files to Modify

### 1. **Core Implementation**

| File                                       | Type   | Purpose                                                                                        |
| ------------------------------------------ | ------ | ---------------------------------------------------------------------------------------------- |
| `scripts/lib/pipeline-stages-monitor.sh`   | Modify | Enhance `stage_validate()` to add post-merge validation, Checks API polling, auto-revert logic |
| `scripts/lib/pipeline-merge-validation.sh` | Create | Helper functions for state machine, safe revert, issue reopening, lock management              |
| `scripts/lib/pipeline-merge-checks.sh`     | Create | Helper functions for Checks API polling with timeout and backoff                               |

### 2. **Configuration**

| File                                  | Type   | Purpose                                                 |
| ------------------------------------- | ------ | ------------------------------------------------------- |
| `templates/pipelines/standard.json`   | Modify | Enable validate stage, add post_merge_validation config |
| `templates/pipelines/full.json`       | Modify | Enable validate stage, add post_merge_validation config |
| `templates/pipelines/autonomous.json` | Modify | Enable validate stage, add post_merge_validation config |
| `templates/pipelines/deployed.json`   | Modify | Enable validate stage, add post_merge_validation config |
| `templates/pipelines/enterprise.json` | Modify | Enable validate stage, add post_merge_validation config |
| `templates/pipelines/cost-aware.json` | Modify | Enable validate stage, add post_merge_validation config |

### 3. **Tests**

| File                                  | Type   | Purpose                                                                                   |
| ------------------------------------- | ------ | ----------------------------------------------------------------------------------------- |
| `scripts/sw-merge-validation-test.sh` | Create | Unit & integration tests for state machine, revert logic, Checks API polling, async retry |
| `scripts/sw-pipeline-test.sh`         | Modify | Add E2E test for full validate stage post-merge flow                                      |

### 4. **Documentation**

| File                                                             | Type   | Purpose                                        |
| ---------------------------------------------------------------- | ------ | ---------------------------------------------- |
| `scripts/skills/generated/merge-validation-and-revert-safety.md` | Exists | Reference for patterns (already comprehensive) |

---

## Implementation Steps

### Phase 1: Foundation & Infrastructure (Tasks 1-3)

**Task 1: Create pipeline-merge-validation.sh helper library**

- [ ] Implement state machine functions:
  - `validation_state_init(merge_commit_sha)` — Initialize state JSON
  - `validation_state_transition(new_state)` — Atomic state transition with locking
  - `validation_state_read()` — Read current state safely
- [ ] Implement lock functions:
  - `validation_lock_acquire()` — flock with 30-min timeout
  - `validation_lock_release()` — Release flock
- [ ] Add to source chain in pipeline-stages-monitor.sh

**Task 2: Create pipeline-merge-checks.sh helper library**

- [ ] Implement Checks API polling:
  - `checks_poll_required_checks(owner, repo, commit_sha, timeout_s)` — Poll until completion or timeout
  - `checks_require_passed(response_json)` — Parse response and check if all required checks passed
  - Uses `sw-github-checks.sh` module under the hood
- [ ] Exponential backoff: 1s → 2s → 4s → 8s (max 8s)
- [ ] Timeout logic: Return success (fail-open) after `timeout_s`
- [ ] Response logging: Append to `.claude/pipeline-artifacts/checks-responses.jsonl`

**Task 3: Create safe revert helper functions**

- [ ] `revert_is_already_applied(merge_commit_sha)` — Check `git log --grep="Revert"` for idempotency
- [ ] `revert_is_head_different(merge_commit_sha)` — Check if HEAD has moved (no-cascade check)
- [ ] `revert_commit(merge_commit_sha)` — Execute `git revert --no-edit` and verify result
- [ ] `revert_verify(merge_commit_sha)` — Confirm SHA actually changed post-revert
- [ ] Error handling: Return specific codes for conflict vs. permission denied vs. success

---

### Phase 2: Enhance Validate Stage (Tasks 4-6)

**Task 4: Modify stage_validate() to detect post-merge context**

- [ ] Read merge_commit_sha from last completed merge stage (stored in artifacts)
- [ ] Check if post_merge_validation is enabled in pipeline config
- [ ] If not post-merge: use existing smoke test flow (no revert logic)
- [ ] If post-merge: proceed to Checks API polling

**Task 5: Implement Checks API polling in validate stage**

- [ ] Call `checks_poll_required_checks()` with merge commit SHA
- [ ] On success: set state to STATE_SUCCESS, log event, continue to issue closure
- [ ] On timeout: assume success (fail-open), log warning, emit event `merge.validation.checks_timeout`
- [ ] On failure: set state to STATE_FAILED, proceed to revert decision

**Task 6: Implement auto-revert decision logic**

- [ ] On validation failure, call `validation_state_transition(STATE_FAILED)`
- [ ] Check `revert_is_head_different()` — if yes, skip revert (no-cascade), log event
- [ ] Check `revert_is_already_applied()` — if yes, skip revert (idempotency), log event
- [ ] Decide: proceed with revert attempt
- [ ] Call `revert_commit()` with proper error handling
- [ ] On success: STATE_REVERTED
- [ ] On conflict/permission failure: STATE_REVERT_FAILED

---

### Phase 3: Issue & Memory Management (Tasks 7-9)

**Task 7: Implement issue reopening with async retry**

- [ ] Parse original issue number from pipeline context
- [ ] Build failure context:
  - Merge commit SHA
  - Validation start/end time
  - Failed test names (from smoke tests)
  - Revert commit SHA (if reverted)
- [ ] Call `gh issue reopen $issue_num --comment "..."` with summary
- [ ] Add label: `validation-failed`
- [ ] On failure: Write to `.claude/pipeline-artifacts/pending-issue-reopens.jsonl`
- [ ] Circuit breaker: If 3 consecutive failures for same issue, alert and stop

**Task 8: Implement memory logging**

- [ ] Log validation outcome to `~/.shipwright/memory/<repo-hash>/validation-failures.jsonl`
- [ ] Fields: commit SHA, smoke test failed, checks API timeout, revert success, root cause category
- [ ] Used by intelligence modules to flag risky patterns
- [ ] Retention: Keep last 100 entries

**Task 9: Add configuration to pipeline templates**

- [ ] Update `templates/pipelines/standard.json`:
  - Set `validate.enabled = true`
  - Add `post_merge_validation = true`
  - Add `auto_revert = true`
  - Set `post_merge_smoke_cmd = "npm test -- --testPathPattern=smoke"`
  - Set `checks_poll_timeout_s = 180`
  - Set `revert_timeout_min = 15`
- [ ] Repeat for: full.json, autonomous.json, deployed.json, enterprise.json, cost-aware.json
- [ ] For fast.json & hotfix.json: Keep validate disabled (not relevant for quick fixes)

---

### Phase 4: Testing (Tasks 10-13)

**Task 10: Unit tests for state machine**

- [ ] `sw-merge-validation-test.sh`:
  - Test `validation_state_init()` creates valid JSON
  - Test atomic transitions (VALIDATING → SUCCESS, VALIDATING → FAILED, FAILED → REVERTING, etc.)
  - Test lock acquire/release behavior
  - Test state corruption handling (reset to VALIDATING)

**Task 11: Unit tests for Checks API polling**

- [ ] Mock `gh api` responses
- [ ] Test success case: checks passed → return success
- [ ] Test timeout case: 180s elapsed → assume success
- [ ] Test failure case: required check failed → return failure
- [ ] Test exponential backoff: verify delay sequence (1, 2, 4, 8s)
- [ ] Test response logging: entries written to checks-responses.jsonl

**Task 12: Unit tests for revert logic**

- [ ] Mock `git revert`, `git log`, `git rev-parse`
- [ ] Test idempotency: already reverted → skip revert
- [ ] Test no-cascade: HEAD moved → skip revert
- [ ] Test conflict: revert fails → STATE_REVERT_FAILED
- [ ] Test success: revert applies → verify SHA changed → STATE_REVERTED
- [ ] Test issue reopening success and async retry queue

**Task 13: E2E integration test**

- [ ] Create test repo with mock commits
- [ ] Simulate merge completion
- [ ] Trigger validate stage with post_merge_validation enabled
- [ ] Mock Checks API: return failure
- [ ] Verify: state transitions, revert attempted, issue reopened, memory logged
- [ ] Test async retry queue: simulate reopening failure, verify queued, verify next run processes queue

---

### Phase 5: Documentation & Rollout (Tasks 14-15)

**Task 14: Update CLAUDE.md and README**

- [ ] Document new validate stage post-merge behavior
- [ ] Explain when auto-revert is triggered
- [ ] Document configuration flags and defaults
- [ ] Add examples: "Viewing validation failures", "Disabling auto-revert for hot repos"

**Task 15: Version bump and release prep**

- [ ] Increment version in package.json (3.3.0 → 3.3.1)
- [ ] Verify test suite passes
- [ ] Create changelog entry
- [ ] Tag and release (handled by shipwright release process)

---

## Task Checklist

- [ ] **Task 1** — Create pipeline-merge-validation.sh with state machine & lock functions
- [ ] **Task 2** — Create pipeline-merge-checks.sh with Checks API polling & exponential backoff
- [ ] **Task 3** — Create safe revert helpers (idempotency, no-cascade, conflict detection)
- [ ] **Task 4** — Detect post-merge context in stage_validate()
- [ ] **Task 5** — Implement Checks API polling in validate stage
- [ ] **Task 6** — Implement auto-revert decision logic with proper error handling
- [ ] **Task 7** — Implement issue reopening with async retry queue & circuit breaker
- [ ] **Task 8** — Implement memory logging for validation patterns
- [ ] **Task 9** — Update pipeline templates (6 templates) with post-merge validation config
- [ ] **Task 10** — Write unit tests for state machine
- [ ] **Task 11** — Write unit tests for Checks API polling
- [ ] **Task 12** — Write unit tests for revert logic & issue reopening
- [ ] **Task 13** — Write E2E integration test for full validate → revert → reopen flow
- [ ] **Task 14** — Update CLAUDE.md and README documentation
- [ ] **Task 15** — Version bump and release prep

---

## Testing Approach

### Unit Test Coverage

**State Machine Tests** (`sw-merge-validation-test.sh`):

- ✓ State initialization: JSON structure, epoch timestamp, commit SHA recorded
- ✓ State transitions: All valid transitions succeed, invalid transitions fail
- ✓ Locking: Acquire succeeds, timeout breaks lock, concurrent access serialized
- ✓ Corruption: Invalid JSON detected, reset to VALIDATING

**Checks API Tests**:

- ✓ Success: All required checks passed → validation succeeds
- ✓ Failure: Required check failed → validation fails, details captured
- ✓ Timeout: 180s elapsed → assume success, log warning
- ✓ Network error: Retries with exponential backoff, eventually times out
- ✓ Response logging: All responses appended to checks-responses.jsonl

**Revert Logic Tests**:

- ✓ Idempotency: Already-reverted commit skipped
- ✓ No-cascade: HEAD moved, skip revert, log event
- ✓ Clean revert: git revert succeeds, SHA changes, STATE_REVERTED
- ✓ Merge conflict: git revert fails, STATE_REVERT_FAILED, incident created
- ✓ Permission denied: git revert permission error, STATE_REVERT_FAILED
- ✓ Issue reopening: Success and async retry queue behavior

### Integration Test Coverage

**E2E Post-Merge Validation Flow**:

1. Setup: Create feature branch, make commit, merge to main
2. Trigger: Validate stage runs post-merge
3. Checks API: Mock required checks (failure)
4. Smoke tests: Mock test failure
5. Revert: Verify revert commit created
6. Issue: Verify issue reopened with `validation-failed` label
7. Memory: Verify failure logged to memory
8. Idempotency: Re-run validation, verify no second revert

### Critical Paths

| Path              | Test Case                           | Expected Result                           |
| ----------------- | ----------------------------------- | ----------------------------------------- |
| Happy path        | Checks pass + smoke tests pass      | STATE_SUCCESS, issue closed, complete     |
| Checks fail       | Checks API returns failure          | STATE_FAILED → revert → STATE_REVERTED    |
| Smoke fail        | Smoke tests return non-zero         | STATE_FAILED → revert → STATE_REVERTED    |
| Timeout           | Checks API timeout after 180s       | Assume success (fail-open), STATE_SUCCESS |
| Revert conflict   | git revert has merge conflict       | STATE_REVERT_FAILED, incident created     |
| Already reverted  | Commit already has revert commit    | Skip revert, idempotency preserved        |
| Head moved        | New commit landed during validation | Skip revert, no-cascade logic triggered   |
| Issue reopen fail | gh issue reopen fails               | Write to pending queue, retry next run    |

### Test Harness Pattern

```bash
# Mock GitHub Checks API response
_mock_checks_response() {
  cat <<EOF
{
  "total_count": 2,
  "check_runs": [
    {"name": "tests", "status": "completed", "conclusion": "success"},
    {"name": "lint", "status": "completed", "conclusion": "failure"}
  ]
}
EOF
}

# Mock git revert
git() {
  case "$2" in
    revert) echo "revert success"; return 0 ;;
    *) command git "$@" ;;
  esac
}

# Run test
stage_validate
# Verify state file
jq . .claude/pipeline-artifacts/validation-state.json | grep -q "STATE_FAILED"
```

---

## Definition of Done

✓ **Implementation Complete**

- [ ] All 15 tasks completed (see Task Checklist)
- [ ] No TODOs in code
- [ ] All helper functions documented with comments

✓ **Testing Complete**

- [ ] Unit tests: All state machine, Checks API, revert logic paths covered
- [ ] Integration tests: Full E2E flow tested (merge → validate → revert → reopen → memory log)
- [ ] Test coverage: ≥80% for pipeline-merge-validation.sh & pipeline-merge-checks.sh
- [ ] npm test passes (all test suites)

✓ **Configuration Complete**

- [ ] Pipeline templates updated (6 templates)
- [ ] Default values documented
- [ ] Backward compatibility verified (old pipelines without post_merge_validation config work)

✓ **Memory System Integrated**

- [ ] Validation failures logged to memory
- [ ] At least 3 real validation scenarios captured
- [ ] Memory queries show patterns (e.g., "flaky test vs. real regression")

✓ **Documentation Complete**

- [ ] CLAUDE.md updated with validate stage post-merge behavior
- [ ] README updated with new feature description
- [ ] Inline comments explain tricky logic (state transitions, no-cascade, idempotency)

✓ **Operational Readiness**

- [ ] Validation-failed issues can be manually created and reopened
- [ ] Lock timeout (30 min) works and is documented
- [ ] Operator can disable auto-revert via config
- [ ] Logs contain enough detail to debug failures (event types, commit SHAs, check results)

✓ **Release Ready**

- [ ] Version bumped (3.3.0 → 3.3.1 or per semver)
- [ ] CHANGELOG.md entry added
- [ ] All tests pass in CI
- [ ] No regressions in existing validate stage behavior

---

## Risk Mitigation Summary

| Risk                     | Severity | Mitigation                                                            | Status              |
| ------------------------ | -------- | --------------------------------------------------------------------- | ------------------- |
| Revert merge conflict    | Critical | Detect failure, create incident, circuit breaker on repeated failures | ✓ Covered in Task 6 |
| Checks API timeout       | Medium   | Exponential backoff, fail-open, response logging                      | ✓ Covered in Task 5 |
| Cascading reverts        | High     | Commit SHA lockfile, no-cascade check                                 | ✓ Covered in Task 6 |
| State file corruption    | High     | Atomic writes, JSON validation, reset on corruption                   | ✓ Covered in Task 1 |
| Issue reopen failure     | Medium   | Async retry queue, circuit breaker                                    | ✓ Covered in Task 7 |
| Simultaneous validations | Medium   | flock-based locking, 30-min timeout                                   | ✓ Covered in Task 1 |

---

## Success Metrics

After implementation, success is verified by:

1. **Functional**: Merge validation runs automatically post-merge, auto-reverts on failure
2. **Reliability**: 99% success rate for revert operations (conflicts are the exception, not norm)
3. **Observability**: Memory log shows clear patterns of what causes main to fail
4. **Operational**: Operators can track validation outcomes via logs and event stream
5. **Performance**: Validation completes within 15 min (smoke tests + Checks API polling)

---

## Next Steps

1. ✅ **This Plan**: Create detailed implementation plan (current stage)
2. → **Design Review**: Verify plan with team (if applicable)
3. → **Task 1-3**: Implement helper libraries
4. → **Task 4-9**: Enhance validate stage and update templates
5. → **Task 10-13**: Comprehensive testing
6. → **Task 14-15**: Documentation and release
7. → **Rollout**: Deploy to production, monitor validation patterns
