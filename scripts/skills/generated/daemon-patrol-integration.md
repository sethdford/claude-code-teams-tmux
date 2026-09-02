## Daemon Patrol Integration

When adding new automatic actions to the Shipwright daemon patrol system (e.g., issue closure, label mutations, comment posting), follow these patterns to ensure safety, reversibility, and observability.

### Integration Architecture

**Execution Model**: Patrol checks run serially in the main daemon polling loop (never concurrent), so no file locking or race condition handling needed. Each check is a separate shell function that reads GitHub state and decides on an action.

**Registration**: Add new patrol function to `lib/daemon-patrol.sh` or as a discrete section in `sw-daemon.sh`, following the naming convention `patrol_check_<name>()`. Export the function name in the main daemon dispatch so it's called every poll cycle.

**Dry-Run Support**: Every patrol check must honor `PATROL_DRY_RUN=1` environment variable. In dry-run mode:
- Log intended actions ("Would close issue #123 because...") to stdout/stderr
- Do NOT call GitHub API
- Exit with the same code as production run (0 for success) so orchestration logic works unchanged
- Useful for testing and auditing before daemon deployment

### False-Positive Prevention

**Normalization Strategy**: Normalize titles conservatively to avoid over-matching:
- Lowercase and strip punctuation
- Collapse multiple spaces, leading/trailing whitespace
- Do NOT remove words; do NOT do substring matching on individual words
- Example: "E2E test: add comment to README [automated]" → "e2e test add comment to readme automated"

**Threshold Enforcement**: Require multiple signals before action (e.g., >3 issues, same label, created within 7 days). Single or dual matches should log a warning but take no action.

**Reversibility**: Design so false positives can be undone:
- Always post a GitHub comment explaining the action and linking to related issues
- Link to the canonical/newest issue so users can check the current work
- Include a "revert by reopening" instruction if the closure was incorrect

### Configuration & Validation

**Schema**: Add new patrol thresholds under `daemon-config.json` `.patrol.*` key:
```json
{
  "patrol": {
    "duplicate_issue_threshold": 3,
    "duplicate_created_within_days": 7,
    "duplicate_dry_run": false
  }
}
```

**Defaults & Validation**: Provide sensible hardcoded defaults; validate config at daemon startup:
- Warn if key is missing (use default)
- Error if value is invalid type (not an integer, negative, etc.)
- Log all config values at daemon startup for audit trail

### Event Emission

Emit structured events for all patrol actions so they appear in the activity stream and cost dashboard:
```bash
emit_event "patrol_action" \
  "check=duplicate_closure" \
  "issue=$issue_id" \
  "action=closed" \
  "reason=clustered_near_duplicates" \
  "related_issues=$issue_ids_closed"
```

### Testing Patterns

**Unit Tests**: Mock GitHub API; test with `PATROL_DRY_RUN=1` and real API calls separately:
- 0 issues matching pattern → no-op
- N issues matching pattern (N < threshold) → no-op, log warning
- N issues matching pattern (N >= threshold) → closes N-1 oldest, keeps newest
- Threshold exactly at boundary (N == threshold) → behavior defined
- All issues created on same minute → deterministic by issue number
- GitHub API failure (network error, rate limit) → backoff, log error, retry next poll

**Integration Tests**: With mocked GitHub responses; verify:
- Dry-run mode logs intended actions without API calls
- Production mode calls GitHub API and posts comment
- Comment text is clear and links to canonical issue

### Monitoring & Observability

**Dashboards**: Provide `shipwright status --patrol` output:
```
Patrol Actions (Last 24h)
  duplicate_closure    14 closed    2 dry-run
  stale_branch_cleanup 8 deleted    1 error
```

**Metrics**:
- "patrol_actions_total" (counter by check name, action, outcome)
- "patrol_false_positives" (user-reported, distinct from intentional actions)
- "patrol_latency_seconds" (time for entire patrol cycle)

**Audit Trail**: Log patrol actions in a side file (`.claude/pipeline-artifacts/patrol-log.jsonl`) with full context (before/after issue state, rationale, user who can revert).

### Example: Duplicate Issue Closure

```bash
patrol_check_duplicate_issues() {
  local threshold=${PATROL_DUP_THRESHOLD:-3}
  local window_days=${PATROL_DUP_WINDOW_DAYS:-7}
  
  # Fetch open issues, normalize titles, group by pattern
  # For each group with >= threshold issues:
  # - Identify newest by created_at
  # - Close all others with explanatory comment
  # - Emit event
  # - If PATROL_DRY_RUN=1, log without calling GitHub API
}
```
