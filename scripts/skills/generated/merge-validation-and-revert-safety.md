## Merge Validation and Revert Safety Patterns

Post-merge validation reverting is a high-risk operation—you're undoing a decision the team made. Safe patterns prevent cascading failures, race conditions, and inconsistent state.

### State Machine Design

Track validation state atomically in a single file to prevent splits (test passed but revert failed = inconsistent):

```
STATE_VALIDATING → STATE_SUCCESS → complete
              ↓
           STATE_FAILED → STATE_REVERTING → STATE_REVERTED → reopen_issue → complete
                                    ↓
                           STATE_REVERT_FAILED → alert_human
```

Write state to `.claude/pipeline-artifacts/validation-state.json` with SHA of the commit being validated. Each transition is atomic (write tmp file, mv). Never partially transition.

### Distributed State: The 15-Min Window

Validation spans ~15 minutes (tests + CI polling). During this window:
- New commits can land on main
- Another merge validation can start on the new commit
- Team members might manually intervene

Prevention patterns:
1. **Commit SHA lockfile**: Validation state must identify THE commit being validated by SHA. If HEAD has moved, skip revert even if validation failed.
2. **No cascading**: If validating commit N and find commit N+1 already arrived, stop—don't revert N. Let N+1's validation run.
3. **Idempotent revert attempts**: Reverting twice = creates two revert commits (bad). Use `git log --grep="Revert"` to detect if commit is already reverted; skip if so.

### Revert Safety: Who Can Trigger It?

Revert is destructive. Patterns:
- **CI-only**: Only pre-approved CI checks can fail validation (e.g., required GitHub Checks). Flaky tests must not trigger reverts.
- **Human approval**: For high-risk repos, require manual approval before revert (async gate in issue comment).
- **Limits**: Revert only if validation failed within 15 min AND fewer than N reverts in the past 7 days. Escalate to human if revert rate spikes.

### Partial Failure Recovery

Revert succeeds but issue reopening fails = broken state. Patterns:
1. **Revert verification before cleanup**: After revert commit, verify HEAD actually moved by comparing pre/post SHA.
2. **Async issue operations**: Issue reopening can fail asynchronously. If it fails, write to `.claude/pipeline-artifacts/pending-issue-reopens.jsonl`. Next validation run processes the backlog.
3. **Circuit breaker**: If issue reopening fails 3 times in a row, stop attempting and alert (don't silently accumulate failed reopens).

### Memory Injection: Learning from Failures

Patterns stored in `~/.shipwright/memory/<repo-hash>/validation-failures.jsonl`:
- Commit SHA, test that failed, time to detection, whether revert helped
- Root cause category (flaky test, real regression, environment issue)
- Build a failure index: commits that failed validation but should have reverted vs. commits that reverted and then passed on retry

### GitHub API Resilience

Checks API is eventually consistent:
- Retry polling up to 180s (3 min) waiting for required checks to complete
- Use exponential backoff (1s → 2s → 4s → 8s)
- After timeout, assume validation PASSED (fail-open). Better to merge a regression than lock main.
- Store all Checks API responses in `.claude/pipeline-artifacts/checks-responses.jsonl` for debugging

### Testing All Paths

Must mock:
- GitHub Checks API: success, timeout, failure, partial response
- `git revert`: success, merge conflict (revert can't apply), permission denied
- Issue reopening: success, 404 (issue deleted), 422 (can't reopen locked issue)
- State file corruption (write fails partway through)

Each mock must be independently testable in unit tests, then composed in integration tests.
