## E2E Test Quarantine Validation

Shipwright's E2E integration test harness creates synthetic GitHub issues for testing. These must be properly quarantined to prevent pollution of production analytics, daemon issue processing, and strategic analysis.

### Quarantine System Architecture

**Label-based filtering**: Tests apply `sw:e2e-test` label (configurable via `labels.e2e_test` in daemon-config.json) at issue creation. Eight downstream consumers filter quarantined issues: daemon poll, triage, strategic analysis, issue decompose, fleet analytics, and three others.

**Fail-safe contract**: If label application fails, jq malforms, or JSON is invalid, issues pass through unfiltered (visible noise beats silent starvation).

### Implementation Checklist

- [ ] Apply `sw:e2e-test` label immediately after issue creation, before any daemon/automation processes it
- [ ] Test scenario is idempotent and can run multiple times without side effects
- [ ] GitHub API interactions happen only on synthetic repos or isolated test branches
- [ ] Cleanup phase verifies labels were applied and respected throughout execution
- [ ] Test output documents which quarantine consumer paths were verified (daemon skip, triage skip, etc.)

### GitHub API Testing

When testing interactions like comments:
- Use GitHub API to confirm comment was added (not direct file reads)
- Verify quarantine labels persist after comment addition
- Query open issues list to confirm test issue is skipped by consumers
- Validate comment can be cleaned up without leaving orphans

### Common Pitfalls

- Label applied after daemon has already queued the issue
- Comment added via direct file modification instead of API (doesn't test API layer)
- Cleanup incomplete: comment or label remains after test
- No validation that downstream consumers actually skip the test issue
