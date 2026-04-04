# Migration Guide: Fallback Pattern Elimination

Hardcoded fallback values in 7 scripts have been centralized into `config/defaults.json` and are now read through the 4-level config precedence chain.

## What Changed

Previously, tunables like iteration limits, model pricing, and health score weights were hardcoded in script source. Now they live in `config/defaults.json` and can be overridden at any level of the config chain.

## Config Precedence (unchanged)

1. **Environment variable** `SHIPWRIGHT_<SECTION>_<KEY>` (highest priority)
2. **daemon-config.json** `.claude/daemon-config.json`
3. **policy.json** `config/policy.json`
4. **defaults.json** `config/defaults.json` (lowest priority)

## New Config Keys

### `loop` section

| Key | Default | Old Location |
|-----|---------|-------------|
| `loop.model` | `"opus"` | `sw-loop.sh:84` `${SW_MODEL:-opus}` |
| `loop.fallback_model` | `"sonnet"` | `sw-loop.sh:131` `${SW_FALLBACK_MODEL:-sonnet}` |
| `loop.max_iterations` | `20` | `sw-loop.sh:79` `${SW_MAX_ITERATIONS:-20}` |
| `loop.auto_extend` | `true` | `sw-loop.sh:105` hardcoded |
| `loop.extension_size` | `5` | `sw-loop.sh:106` hardcoded |
| `loop.max_extensions` | `3` | `sw-loop.sh:107` hardcoded |
| `loop.circuit_breaker_threshold` | `3` | `sw-loop.sh:111` hardcoded |
| `loop.min_progress_lines` | `5` | `sw-loop.sh:112` hardcoded |

### `daemon` section

| Key | Default | Old Location |
|-----|---------|-------------|
| `daemon.patrol_interval` | `3600` | `sw-daemon.sh:239` `${PATROL_INTERVAL:-3600}` |
| `daemon.patrol_max_issues` | `5` | `sw-daemon.sh:240` `${PATROL_MAX_ISSUES:-5}` |
| `daemon.patrol_label` | `"auto-patrol"` | `sw-daemon.sh:241` `${PATROL_LABEL:-auto-patrol}` |
| `daemon.on_failure_log_lines` | `50` | `sw-daemon.sh:213` hardcoded |

### `cost` section

| Key | Default | Old Location |
|-----|---------|-------------|
| `cost.opus_input_per_m` | `15.00` | `sw-cost.sh:69` hardcoded |
| `cost.opus_output_per_m` | `75.00` | `sw-cost.sh:70` hardcoded |
| `cost.sonnet_input_per_m` | `3.00` | `sw-cost.sh:71` hardcoded |
| `cost.sonnet_output_per_m` | `15.00` | `sw-cost.sh:72` hardcoded |
| `cost.haiku_input_per_m` | `0.25` | `sw-cost.sh:73` hardcoded |
| `cost.haiku_output_per_m` | `1.25` | `sw-cost.sh:74` hardcoded |

### `vitals` section

| Key | Default | Old Location |
|-----|---------|-------------|
| `vitals.weight_momentum` | `35` | `sw-pipeline-vitals.sh:46` |
| `vitals.weight_convergence` | `30` | `sw-pipeline-vitals.sh:47` |
| `vitals.weight_budget` | `20` | `sw-pipeline-vitals.sh:48` |
| `vitals.weight_error_maturity` | `15` | `sw-pipeline-vitals.sh:49` |

### `predictive` section

| Key | Default | Old Location |
|-----|---------|-------------|
| `predictive.anomaly_threshold` | `3.0` | `sw-predictive.sh:55` |
| `predictive.warning_multiplier` | `2.0` | `sw-predictive.sh:56` |
| `predictive.ema_alpha` | `0.1` | `sw-predictive.sh:57` |

### `model_router` section

| Key | Default | Old Location |
|-----|---------|-------------|
| `model_router.complexity_low` | `30` | `sw-model-router.sh:71` |
| `model_router.complexity_high` | `80` | `sw-model-router.sh:72` |

### `fleet` section

| Key | Default | Old Location |
|-----|---------|-------------|
| `fleet.metrics_period` | `7` | `sw-fleet.sh:98` |

## Breaking Change: `context_budget_chars`

The default for `loop.context_budget_chars` was `200000` in `sw-loop.sh` but `180000` in `defaults.json`. The canonical value is now `180000` (from `defaults.json`). If you relied on the higher value, set it explicitly:

```json
// .claude/daemon-config.json
{
  "loop": {
    "context_budget_chars": 200000
  }
}
```

Or via environment variable: `SHIPWRIGHT_LOOP_CONTEXT_BUDGET_CHARS=200000`.

## How to Override

**Per-repo** (daemon-config.json):
```json
{
  "vitals": {
    "weight_momentum": 40,
    "weight_convergence": 25
  },
  "cost": {
    "opus_input_per_m": 12.50
  }
}
```

**Via environment** (highest priority):
```bash
export SHIPWRIGHT_LOOP_MODEL=sonnet
export SHIPWRIGHT_VITALS_WEIGHT_MOMENTUM=40
```

## Config Validation

A new `_config_validate` function validates `defaults.json` and `daemon-config.json` against `config/defaults.schema.json`:

```bash
# Source config.sh, then:
_config_validate           # Warn on errors, always returns 0
_config_validate --strict  # Exit 1 on errors (for daemon startup)
```

Validation catches type mismatches (string where integer expected) and unknown keys in sections with `additionalProperties: false`.

## Rollback

If any issue arises, the migration is backward-compatible:
- All scripts still have inline fallback values as a last resort
- If `defaults.json` is missing or `jq` is unavailable, scripts use their hardcoded defaults
- Environment variable overrides continue to work exactly as before
