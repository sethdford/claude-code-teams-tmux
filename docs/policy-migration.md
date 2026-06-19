# Hardcoded Policy Migration Guide

This document describes the migration of hardcoded numeric thresholds, timeouts, and limits to the centralized policy system via `config/policy.json` and the `_policy_int` runtime reader.

## Overview

The policy migration engine identifies hardcoded values in shell scripts and provides a structured path to migrate them to the `tunables` section of `config/policy.json`. This enables:

- **Central configuration** — All numeric thresholds in one place
- **Adaptive tuning** — Self-optimizing daemon can adjust parameters at runtime
- **Environment override** — `SW_*` env vars take precedence over config
- **Backward compatibility** — Fallback to original hardcoded default if policy absent

## Top 20 Refactored Values

These values have been migrated to use `_policy_int` for reading from `config/policy.json`:

### Daemon Section

| Variable                  | File         | Line | Default | Env Var                             | Refactored |
| ------------------------- | ------------ | ---- | ------- | ----------------------------------- | ---------- |
| PATROL_FAILURES_THRESHOLD | sw-daemon.sh | 244  | 3       | SW_DAEMON_PATROL_FAILURES_THRESHOLD | ✓          |
| PATROL_RETRY_THRESHOLD    | sw-daemon.sh | 248  | 2       | SW_DAEMON_PATROL_RETRY_THRESHOLD    | ✓          |
| AUTO_SCALE_INTERVAL       | sw-daemon.sh | 228  | 5       | SW_DAEMON_AUTO_SCALE_INTERVAL       | ✓          |
| MAX_WORKERS               | sw-daemon.sh | 232  | 8       | SW_DAEMON_MAX_WORKERS               | ✓          |
| MIN_WORKERS               | sw-daemon.sh | 233  | 1       | SW_DAEMON_MIN_WORKERS               | ✓          |
| BACKOFF_SECS              | sw-daemon.sh | 259  | 0       | SW_DAEMON_BACKOFF_SECS              | ✓          |

### Loop Section

| Variable           | File       | Line | Default | Env Var                    | Refactored |
| ------------------ | ---------- | ---- | ------- | -------------------------- | ---------- |
| FAST_TEST_INTERVAL | sw-loop.sh | 95   | 5       | SW_LOOP_FAST_TEST_INTERVAL | ✓          |

### Adaptive Section

| Variable    | File           | Line | Default | Env Var                 | Refactored |
| ----------- | -------------- | ---- | ------- | ----------------------- | ---------- |
| MIN_TIMEOUT | sw-adaptive.sh | 48   | 60      | SW_ADAPTIVE_MIN_TIMEOUT | ✓          |
| MAX_TIMEOUT | sw-adaptive.sh | 49   | 7200    | SW_ADAPTIVE_MAX_TIMEOUT | ✓          |

### Auth Section

| Variable      | File       | Line | Default | Env Var               | Refactored |
| ------------- | ---------- | ---- | ------- | --------------------- | ---------- |
| OAUTH_TIMEOUT | sw-auth.sh | 47   | 900     | SW_AUTH_OAUTH_TIMEOUT | ✓          |

### Cleanup Section

| Variable                | File          | Line | Default | Env Var                            | Refactored |
| ----------------------- | ------------- | ---- | ------- | ---------------------------------- | ---------- |
| HEARTBEAT_STALE_SECONDS | sw-cleanup.sh | 254  | 3600    | SW_CLEANUP_HEARTBEAT_STALE_SECONDS | ✓          |

## Deferred Values (28 Remaining)

These values are documented here for future migration. They were identified by the scanner but not yet refactored:

### Test-Only Values (Low Priority)

These appear only in test files and do not affect runtime behavior:

- `sw-daemon-test.sh:699` — HEALTH_STALE_TIMEOUT (1800)
- `sw-daemon-test.sh:767` — DEGRADATION_CFR_THRESHOLD (30)
- `sw-daemon-test.sh:768` — DEGRADATION_SUCCESS_THRESHOLD (50)
- `sw-daemon-test.sh:860` — PATROL_FAILURES_THRESHOLD (3) _test fixture_
- `sw-daemon-test.sh:1081` — PROGRESS_HARD_LIMIT_S (10800)
- `sw-lib-daemon-failure-test.sh:151-177` — MAX_RETRIES variants (5-6)
- `sw-lib-daemon-poll-test.sh:*` — BACKOFF_SECS variants (multiple)
- `sw-mutation-executor-test.sh:279,282` — MUTATION_MAX_MUTANTS (5, 50)
- `sw-session-restart-test.sh:*` — Loop/restart control values

### Integration Test Values

- `sw-e2e-integration-test.sh:40` — PIPELINE_TIMEOUT (600)
- `sw-integration-claude-test.sh:15` — SCRIPT_TIMEOUT (120)

### Feature-Specific Values

- `sw-connect.sh:51` — HEARTBEAT_INTERVAL (10)
- `sw-decompose.sh:46` — COMPLEXITY_THRESHOLD (70)
- `sw-decompose.sh:48` — HOURS_THRESHOLD (8)
- `sw-decompose.sh:50` — MAX_SUBTASKS (5)
- `sw-decompose.sh:52` — MIN_SUBTASKS (3)
- `sw-feedback.sh:41` — ERROR_THRESHOLD (5)
- `sw-fix.sh:49` — MAX_PARALLEL (3)
- `sw-predictive.sh:55` — DEFAULT_ANOMALY_THRESHOLD (3)
- `sw-reaper.sh:24` — INTERVAL (5)
- `sw-security-audit.sh:39-42` — Count initializers (CRITICAL, HIGH, MEDIUM, LOW)

### Optimization Values (Low Impact)

- `sw-adaptive.sh:46,50-55` — Confidence samples, iteration limits, coverage bounds
- `sw-prep.sh:72-73,494-495` — File count initialization (0)

## Refactoring Recipe

To refactor a new value from a hardcoded literal to `_policy_int`:

### Step 1: Identify the Value

```bash
bash scripts/sw-policy-migrate.sh scan | grep "scripts/sw-target.sh"
```

Example output:

```
scripts/sw-target.sh:42    120    MY_TIMEOUT    timeout
```

### Step 2: Add to `config/policy.json`

Add the value to the appropriate section in `tunables`:

```bash
jq '.tunables.section += {
  "my_timeout": {
    "default": 120,
    "env_var": "SW_SECTION_MY_TIMEOUT",
    "adaptive_hint": "adaptive",
    "rationale": "Description of what this timeout controls and why."
  }
}' config/policy.json > /tmp/policy.json && mv /tmp/policy.json config/policy.json
```

**Naming conventions:**

- `section` matches the tunables section (daemon, loop, auth, etc.)
- `key` is snake_case and corresponds to the variable
- `env_var` follows pattern `SW_{SECTION}_{KEY}` in UPPER_CASE
- `adaptive_hint` is one of: `adaptive`, `self-optimize`, or `none`

### Step 3: Refactor the Script

Replace the hardcoded assignment with `_policy_int`:

**Before:**

```bash
MY_TIMEOUT=120
```

**After:**

```bash
MY_TIMEOUT=$(_policy_int section my_timeout 120)
```

The third argument is the **original hardcoded value** — this ensures backward compatibility.

### Step 4: Test

Run the script with and without policy set:

```bash
# Should use config/policy.json value if present, else default
bash scripts/sw-target.sh

# Override via env var
SW_SECTION_MY_TIMEOUT=180 bash scripts/sw-target.sh

# Verify with --verbose or by inspecting runtime value
```

### Step 5: Update Tests

If the script has dedicated tests, verify they still pass:

```bash
npm test -- --grep "sw-target"
```

### Step 6: Commit

```bash
git add config/policy.json scripts/sw-target.sh docs/policy-migration.md
git commit -m "feat: refactor sw-target.sh to use _policy_int for my_timeout"
```

## Resolution Order

`_policy_int` resolves values in this order:

1. **Environment variable** — `SW_SECTION_KEY` if set
2. **Policy file** — Value from `config/policy.json` tunables section
3. **Fallback default** — Original hardcoded value passed as third argument

Example for `_policy_int daemon patrol_failures_threshold 3`:

```bash
# Check 1: Is SW_DAEMON_PATROL_FAILURES_THRESHOLD set?
if [[ -n "${SW_DAEMON_PATROL_FAILURES_THRESHOLD:-}" ]]; then
    value="$SW_DAEMON_PATROL_FAILURES_THRESHOLD"

# Check 2: Is value in config/policy.json?
elif [[ -f config/policy.json ]] && jq -e '.tunables.daemon.patrol_failures_threshold' config/policy.json >/dev/null 2>&1; then
    value=$(jq -r '.tunables.daemon.patrol_failures_threshold.default' config/policy.json)

# Check 3: Use fallback
else
    value=3
fi

echo "$value"
```

## Validation

Run `shipwright doctor` to validate policy configuration:

```bash
shipwright doctor | grep -A 10 "POLICY & TUNABLES"
```

Expected output:

```
  POLICY & TUNABLES
  ──────────────────────────────────────────
  ✓ policy.json is valid JSON
  ✓ tunables section found: 4 sections, 11 values
  ✓ All env_var names follow SW_* convention
  ✓ policy.schema.json found
```

## Schema Validation

The `config/policy.schema.json` file validates the structure of new tunables:

```bash
jq -f config/policy.schema.json config/policy.json
```

If adding new sections or fields, update the schema to validate them.

## Implementation Progress

- ✅ `_policy_int` function in `scripts/lib/compat.sh`
- ✅ `_policy_int` test coverage in `sw-policy-e2e-test.sh`
- ✅ `sw-policy-migrate.sh` scanner tool
- ✅ Top 20 values refactored (daemon, loop, adaptive, auth, cleanup sections)
- ⏳ Remaining 28 values (test fixtures, optional features)
- ✅ `shipwright doctor` validation section
- ⏳ CLI dashboard integration for runtime tuning

## Future Enhancements

1. **Interactive migration** — CLI command to auto-refactor a script
2. **Dashboard tuning** — Real-time parameter adjustment via dashboard
3. **A/B testing** — Policy-driven experiment setup for optimization
4. **Rollback tracking** — Audit trail of tunable changes and their effects
