# Intelligence Feature Validation — Methodology

This document describes how Shipwright measures whether its **intelligence features**
(predictive scoring, adaptive timeouts, model routing, convergence detection,
adversarial review, etc.) actually improve delivery outcomes — and how the
`shipwright intelligence impact` analyzer decides whether to keep or disable each one.

> TL;DR — Every pipeline run is tagged `intel_on` or `intel_off` and recorded.
> The analyzer partitions runs into cohorts, computes per-feature impact and ROI,
> and (only past a strict sample-size gate) auto-disables features that demonstrably
> hurt success rate without paying for themselves.

---

## 1. Data collection

Each completed pipeline run emits one **experiment record** to
`~/.shipwright/intelligence-impact.json` (best-effort; recording never affects the
pipeline's exit status). A record captures:

| Field             | Meaning                                                        |
| ----------------- | -------------------------------------------------------------- |
| `experiment_id`   | Shared id linking paired runs (`run-pair` produces true pairs) |
| `variant`         | `intel_on` or `intel_off`                                      |
| `features`        | Feature names active during the run                            |
| `success`         | Whether the run completed successfully                         |
| `duration_s`      | Wall-clock duration in seconds                                 |
| `cost_usd`        | Estimated token cost                                           |
| `iterations`      | Build-loop iteration count (proxy: stages completed)           |
| `failure_type`    | Failure class when `success=false`                             |
| `ts` / `ts_epoch` | Timestamps                                                     |

The store is a rolling array capped at the last **2000** records.

There are two ways records accumulate:

1. **Retrospective (default).** The pipeline already samples intelligence variation
   via `intelligence.ab_test_ratio` (default `0.2`). The completion hook in
   `lib/pipeline-execution.sh` records each run with the variant that actually ran.
   Cohorts fill up "for free" as the daemon operates — at near-zero marginal cost.
2. **Active pairing (`run-pair`).** On demand, `intelligence impact run-pair --issue N`
   runs the _same_ issue twice — once intelligence-forced-on, once forced-off — under
   a shared `experiment_id`, and records both. This satisfies the literal
   "run identical issues twice" experiment design when a controlled pair is wanted.

---

## 2. Cohorts

For a given analysis window the analyzer builds:

- **Global cohorts:** all `intel_on` runs vs all `intel_off` runs.
- **Per-feature cohorts:** for each feature `F`, runs **with** `F` in `.features`
  vs runs **without** `F`. This isolates one feature's contribution.

For each cohort it computes:

- `success_rate = successes / n`
- `mean_duration`, `mean_cost`, `mean_iterations` (arithmetic means)
- `failure_types` — a histogram of failure classes

---

## 3. Impact score

A single comparable number per feature, blending the deltas of the feature-on cohort
against the feature-off cohort:

```
impact = w_s · Δsuccess_rate  −  w_c · Δcost_norm  −  w_d · Δduration_norm
```

- `Δsuccess_rate = success_rate(on) − success_rate(off)`
- `Δcost_norm`, `Δduration_norm` — cost/duration deltas normalized by the off-cohort
  mean (so a feature that is both slower and pricier scores lower).
- Default weights: `w_s = 0.6`, `w_c = 0.25`, `w_d = 0.15`
  (override via `SW_IMPACT_W_SUCCESS` / `SW_IMPACT_W_COST` / `SW_IMPACT_W_DURATION`).

**Positive impact ⇒ the feature helps.**

---

## 4. ROI

Impact is unit-less; ROI puts the trade-off in dollars so a success-rate gain is
comparable against the marginal cost a feature adds:

```
value_gain = Δsuccess_rate · value_per_success      # default $10/success
extra_cost = mean_cost(on) − mean_cost(off)

ROI = (value_gain − extra_cost) / extra_cost          when extra_cost > 0
    = +∞ (capped 999)                                 when the feature is cheaper AND better
    = −∞ (capped −999)                                when cheaper but worse
```

Override the success valuation via `SW_IMPACT_VALUE_PER_SUCCESS`.

---

## 5. Significance gate

Statistics on tiny samples are noise. Before **any** auto-disable fires, both global
cohorts must have at least **20 runs each** (`SW_IMPACT_MIN_SAMPLES`, acceptance
criterion). Below that threshold:

- `analyze` / `report` still print, but flagged **ADVISORY — insufficient data**.
- `apply` refuses and exits `3` (`INSUFFICIENT_DATA`); the config is never touched.

> Limitation: retrospective cohorts are not perfectly matched pairs (an `intel_off`
> sample might happen to contain easier issues). The `run-pair` harness mitigates this
> by producing matched `experiment_id` pairs, and the n≥20 gate guards against acting
> on skew. Treat advisory reports as directional, not conclusive.

---

## 6. Recommendations

| Verdict        | Condition                                                                                                |
| -------------- | -------------------------------------------------------------------------------------------------------- |
| `KEEP`         | `impact > noise_band`                                                                                    |
| `DISABLE`      | `impact < −noise_band` **and** `ROI < 0` **and** n≥20 both cohorts **and** the feature has a config flag |
| `INCONCLUSIVE` | otherwise (small/zero sample, or impact within the noise band)                                           |

`noise_band` defaults to `0.01` (`SW_IMPACT_NOISE_BAND`).

Features **without** a boolean config flag — `convergence`, `adaptive_timeout`,
`model_routing` — are **report-only**. They are scored and shown but never
auto-disabled, because there is no single flag to flip.

| Feature                                            | Config flag                         |
| -------------------------------------------------- | ----------------------------------- |
| `prediction`                                       | `intelligence.prediction_enabled`   |
| `adversarial`                                      | `intelligence.adversarial_enabled`  |
| `simulation`                                       | `intelligence.simulation_enabled`   |
| `architecture`                                     | `intelligence.architecture_enabled` |
| `composer`                                         | `intelligence.composer_enabled`     |
| `optimization`                                     | `intelligence.optimization_enabled` |
| `convergence`, `adaptive_timeout`, `model_routing` | _(report-only)_                     |

---

## 7. Auto-disable (`apply`)

`shipwright intelligence impact apply` flips every `DISABLE` feature's flag to
`false` in `.claude/daemon-config.json`, and is built to be **safe**:

1. **Gated** — refuses unless n≥20 per cohort.
2. **Backed up** — copies the config to `daemon-config.json.impact-bak` first.
3. **Atomic** — writes to a temp file, validates it parses, then `mv`s into place.
   A corrupt config can never be left behind.
4. **Explained** — writes a sibling `intelligence_impact_notes.<feature>` object
   recording the impact score, ROI, sample sizes, and timestamp.
5. **Previewable** — `--dry-run` prints the intended changes and writes nothing.

### Re-enabling a feature

Edit the flag back to `true` in `daemon-config.json` (and optionally delete the
matching `intelligence_impact_notes` entry). The note documents exactly what was
disabled, why, and when, so the decision is always reversible and auditable.

---

## 8. Command reference

```bash
shipwright intelligence impact status                 # store stats & significance
shipwright intelligence impact analyze [--since N] [--json]
shipwright intelligence impact report  [--month YYYY-MM] [--json]
shipwright intelligence impact run-pair --issue N [--local]
shipwright intelligence impact apply   [--dry-run] [--json]
```

Error codes (in `--json` mode): `BAD_INPUT`, `NO_DATA`, `INSUFFICIENT_DATA`,
`CONFIG_WRITE_FAILED`.
