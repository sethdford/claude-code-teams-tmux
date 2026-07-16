# Tasks — Cost-Aware Model Retry Cascade for Failed Stages

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-772

## Checklist
- [ ] Retry cascade executes on stage failure (when enabled)
- [ ] Models tried in configured order (default: haiku → sonnet → opus)
- [ ] Stage succeeds if any model in cascade succeeds
- [ ] Stage fails if all models exhausted
- [ ] Budget check occurs BEFORE each retry (prevents overspend)
- [ ] Non-retryable failures fail fast without cascading
- [ ] Cost tracking accurate per-attempt
- [ ] Configuration via daemon-config.json (enable/disable, per-stage override)
- [ ] `retry_cascade.enabled` controls feature on/off
- [ ] `retry_cascade.model_order` customizable
- [ ] `retry_cascade.max_cascade_cost_per_stage_usd` enforced
- [ ] `retry_cascade.per_stage_overrides` work for specific stages
- [ ] `config/failure-patterns.json` defines retryable vs non-retryable
- [ ] Unit tests: cascade model selection (correct order)
- [ ] Unit tests: budget validation (prevents overspend)
- [ ] Unit tests: failure classification (retryable vs non-retryable)
- [ ] Integration tests: end-to-end stage failure → cascade → success
- [ ] Integration tests: budget enforcement stops cascade
- [ ] E2E tests: cost tracking accurate across retries
- [ ] All existing tests still pass (backward compatibility)

## Notes
- Generated from pipeline plan at 2026-07-16T04:04:14Z
- Pipeline will update status as tasks complete
