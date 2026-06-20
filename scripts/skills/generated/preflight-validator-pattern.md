## Pre-Flight Validator Pattern

Pre-flight validators run synchronously at CLI entry points, check environment dependencies, and fail fast with actionable guidance. Use this pattern to implement robust environment health checks without blocking normal operations.

### Checkpoint Ordering

1. **Fast checks first** — Disk space, tmux availability (no I/O delays)
2. **Network checks second** — GitHub API rate limits, connectivity (may be slow)
3. **Auth checks last** — Claude CLI validation (requires subprocess, slowest)

Order matters: if disk is full, skip network checks. If network is down, don't bother checking GitHub rate limits.

### Fast-Fail Strategy

- Return immediately on first critical failure (e.g., <500MB disk)
- Collect non-critical warnings and emit them all together
- Never block pipeline start for warnings—only failures
- Each check should have a timeout (e.g., rate limit check times out after 2s)

### Actionable Error Messages

Structure each failure with: (1) what failed, (2) why, (3) how to fix it.

```
GitHub API Rate Limited
  - Current: 45/60 requests remaining
  - Retry in: 23 minutes
  - Fix: Wait or use --skip-preflight if necessary
```

Not just: "GitHub API check failed."

### Environment Mocking for Tests

Mock by overriding check functions, not by manipulating system state:

```bash
# In test
mock_disk_free() { echo 1048576; }  # 1GB
mock_github_rate_limit() { echo 5; }  # 5 requests left
preflight_validate  # Uses mocked functions
```

Do NOT create temp files or consume real disk; do NOT call real GitHub API in tests.

### Event Emission

Emit `preflight-failed` event only on blocking failures. Include:

```json
{
  "type": "preflight-failed",
  "timestamp": "2026-06-20T01:27:37Z",
  "failures": [
    {"check": "disk_space", "reason": "<500MB free", "available_mb": 256}
  ],
  "skip_flag_used": false
}
```

### Integration with CLI

Add a `preflight_validate` function callable from `shipwright pipeline start` before pipeline init:

```bash
if ! preflight_validate; then
  [[ "$SKIP_PREFLIGHT" == "true" ]] && warn "Skipping pre-flight" || exit 1
fi
```

The `--skip-preflight` flag should be documented as "Use only when you've manually verified environment health."

### Extension Points

Design the validator as a registry so new checks can be added:

```bash
register_preflight_check "my_custom_check" "check_function" "critical|warning"
```

This prevents coupling and keeps the core validator stable.
