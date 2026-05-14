# Policy Migration Guide

Shipwright centralizes timeouts, limits, thresholds, and retry counts in `config/policy.json` so platform behavior is tunable without code edits.

## Files

- `config/policy.json` — single source of truth for all policy values
- `config/policy.schema.json` — JSON schema for validation
- `scripts/lib/policy.sh` — runtime loader (source it from any script)
- `~/.shipwright/policy.json` — optional user override (overrides repo policy)

## Library API

Source `scripts/lib/policy.sh` after setting `SCRIPT_DIR` (or `REPO_DIR`):

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/policy.sh"
```

### `policy_get <jq_path> [default]`

Returns the value at the given jq path, or the default if missing. Never fails.

```bash
poll_interval=$(policy_get ".daemon.poll_interval_seconds" 60)
```

### `policy_get_with_override <ENV_VAR> <jq_path> [default]`

Precedence: env var > config file > default. Use this when callers need to override per-invocation.

```bash
poll_interval=$(policy_get_with_override "POLL_INTERVAL" ".daemon.poll_interval_seconds" 60)
# POLL_INTERVAL=30 ./script.sh    # overrides
```

### `validate_policy [file]`

Validates the active policy file (or a given path). Returns 0 on success. Errors go to stderr. Pipeline startup should call this.

```bash
validate_policy || { echo "Invalid policy"; exit 1; }
```

### `policy_file`

Prints the path to the active policy file (empty if none found).

## Override Precedence

1. **Environment variable** (passed to `policy_get_with_override`)
2. **`~/.shipwright/policy.json`** (user override, takes priority over repo file)
3. **`<repo>/config/policy.json`** (committed defaults)
4. **Hardcoded default** (passed to `policy_get`)

## Policy Sections

| Section         | Purpose                                                           | Sample Keys                                                                            |
| --------------- | ----------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `daemon`        | Poll interval, heartbeat timeout, stage timeouts, scaling cadence | `poll_interval_seconds`, `health_heartbeat_timeout`, `stage_timeouts.build`            |
| `pipeline`      | Iterations, convergence cap, quality thresholds                   | `max_iterations_default`, `coverage_threshold_percent`, `quality_gate_score_threshold` |
| `quality`       | Audit weights and gate thresholds                                 | `gate_score_threshold`, `audit_weights`                                                |
| `strategic`     | Strategic agent caps and cooldowns                                | `max_issues_per_cycle`, `cooldown_seconds`                                             |
| `sweep`         | Stale pipeline sweep cadence and retry limits                     | `cron_minutes`, `stuck_threshold_hours`                                                |
| `hygiene`       | Artifact retention                                                | `artifact_age_days`                                                                    |
| `recruit`       | Agent recruitment learning thresholds                             | `self_tune_min_matches`, `match_confidence_threshold`                                  |
| `decision`      | Autonomous decision engine                                        | `cycle_interval_seconds`, `outcome_min_samples`                                        |
| `riskTierRules` | File globs → risk tier (critical/high/medium/low)                 | —                                                                                      |
| `mergePolicy`   | Required checks/reviewers per risk tier                           | —                                                                                      |
| `evidence`      | Evidence collectors (cli/api/browser/db)                          | `artifactMaxAgeMinutes`                                                                |

See `config/policy.json` for the authoritative list of keys and current defaults.

## Migration Pattern (Before → After)

**Before:**

```bash
POLL_INTERVAL=60
sleep "$POLL_INTERVAL"
```

**After:**

```bash
source "$SCRIPT_DIR/lib/policy.sh"
POLL_INTERVAL=$(policy_get_with_override "POLL_INTERVAL" ".daemon.poll_interval_seconds" 60)
sleep "$POLL_INTERVAL"
```

The fallback default (`60`) remains so the script still works if `config/policy.json` is missing.

## Adding a New Policy

1. Add the key to `config/policy.json` under the appropriate section.
2. Update `config/policy.schema.json` if a new section was introduced.
3. Replace the hardcoded value in the script with `policy_get` / `policy_get_with_override`.
4. Document the key in this guide (or trust the section table above).
5. Run `bash scripts/sw-policy-e2e-test.sh` to verify.

## Pre-Commit Hygiene

A pipeline hygiene scan flags new hardcoded policy values. Run locally:

```bash
shipwright hygiene scan-policy
```

CI fails the PR if the count of hardcoded policy values increases.
