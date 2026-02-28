# Design: Context Window Token Waste Analyzer and Optimization Scorer

## Context

Shipwright pipeline agents consume context window tokens across 12 stages. Token waste — prompts built then trimmed, underutilized budgets, excessive loop iterations — directly increases cost and degrades agent accuracy. The codebase already emits structured events that capture context efficiency signals:

- **`loop.context_efficiency`** in `scripts/sw-loop.sh:2468` — per-iteration `raw_prompt_chars`, `trimmed_prompt_chars`, `trim_ratio`, `budget_utilization`, `budget_chars`
- **`loop.context_trimmed`** in `scripts/sw-loop.sh:1740` — per-section `original`/`trimmed`/`budget` char counts
- **`pipeline.prompt_truncated`** in `scripts/lib/pipeline-stages.sh:99` — hard truncation events with `stage`, `original`, `budget`
- **`pipeline.context_exhaustion`** in `scripts/lib/pipeline-stages.sh:1268` — iteration-limit events
- **`costs.json`** at `~/.shipwright/costs.json` — `input_tokens`, `output_tokens`, `cost_usd` per stage/model

The dashboard server (`dashboard/server.ts:3720`) already aggregates `avg_utilization` and `avg_trim_ratio`, and `sw-self-optimize.sh:1190` applies basic threshold rules (>90% utilization → increase budget, >30% trim → reduce verbosity). But there is no unified CLI tool that **scores** efficiency per stage, **detects** specific waste patterns, or **recommends** concrete fixes. This feature fills that gap.

**Constraints:**

- Bash 3.2 compatible (no associative arrays, no `readarray`, no `${var,,}`)
- `set -euo pipefail` with ERR trap
- Must source `lib/compat.sh` and `lib/helpers.sh` with fallbacks
- Atomic file writes (tmp + mv)
- JSON via `jq --arg` (no string interpolation)
- `$NO_GITHUB` checks for any GitHub API features (none needed here)
- All values in events.jsonl are strings — numeric parsing via `jq tonumber`

## Decision

Create a single script `scripts/sw-context-waste.sh` (~650 lines) that reads existing event data, detects 6 waste patterns, computes per-stage and overall efficiency scores (0–100), and generates ranked recommendations. Integrate a summary section into the `sw-cost.sh show` dashboard. Register in the CLI router and test suite.

### Data Flow

```
~/.shipwright/events.jsonl ─┬─ loop.context_efficiency ──┐
                            ├─ loop.context_trimmed ──────┤
                            ├─ pipeline.prompt_truncated ─┤
                            └─ pipeline.context_exhaustion┘
                                       │
~/.shipwright/costs.json ──────────────┤
                                       ▼
                           sw-context-waste.sh
                           ├─ _extract_context_events()
                           ├─ _extract_cost_events()
                           ├─ _extract_prompt_truncations()
                           │
                           ├─ 6 pattern detectors
                           │   ├─ _detect_oversized_prompts
                           │   ├─ _detect_low_utilization
                           │   ├─ _detect_high_trim_waste
                           │   ├─ _detect_repeated_iterations
                           │   ├─ _detect_cost_per_char
                           │   └─ _detect_stage_imbalance
                           │
                           ├─ compute_stage_score()
                           ├─ compute_overall_score()
                           ├─ generate_recommendations()
                           │
                           └─ emit_event("context_waste.analysis")
                                       │
                               ┌───────┴───────┐
                               ▼               ▼
                        CLI output      downstream consumers
                     (show/analyze/     (self-optimize,
                      score/--json)      vitals, patrol)
```

### Scoring Formula

Per-stage score starts at 100 and is penalized:

| Penalty              | Formula                             | Cap |
| -------------------- | ----------------------------------- | --- |
| High trim ratio      | `−min(30, trim_ratio × 0.8)`        | 30  |
| Low utilization      | `−max(0, (50 − utilization) × 0.4)` | 20  |
| Excessive iterations | `−min(20, (iterations − 3) × 5)`    | 20  |
| Pattern detections   | `−5` per detected pattern           | 30  |

Floor is 0. Overall score is a weighted average of stage scores, weighted by token spend per stage from `costs.json`.

### Pattern Detectors

1. **Oversized prompts** — `raw_prompt_chars` exceeds `budget_chars` by >20%. Signals: context built then force-truncated, tokens wasted on construction.
2. **Low utilization** — `budget_utilization` consistently <50% over ≥3 iterations. Signals: paying for unused budget.
3. **High trim waste** — `trim_ratio` >25%. Signals: context sections built then discarded.
4. **Repeated iterations** — >5 iterations for same `job_id`. Signals: thrashing, wasting tokens on retries.
5. **Cost per useful char** — stage cost/useful-chars is >2× the cross-stage average. Signals: expensive model on low-value context.
6. **Stage imbalance** — one stage >60% of total context chars. Signals: pipeline composition is skewed.

### CLI Subcommands

| Subcommand        | Purpose                                                                   | Flags                               |
| ----------------- | ------------------------------------------------------------------------- | ----------------------------------- |
| `show` (default)  | Dashboard: overall score, per-stage scores, top patterns, recommendations | `--json`, `--period N`, `--issue N` |
| `analyze`         | Deep analysis for a specific run                                          | `--issue N`, `--json`               |
| `by-stage`        | Table of stages with score, waste %, cost, primary pattern                | `--json`, `--period N`              |
| `recommendations` | Ranked actionable fixes                                                   | `--json`, `--period N`              |
| `score`           | Numeric score only (for CI: `shipwright context-waste score`)             | `--period N`                        |

### Event Emission

After analysis, emit `context_waste.analysis` with `overall_score`, `worst_stage`, `top_pattern`, `recommendation_count`, `estimated_savings_pct`. This enables `sw-self-optimize.sh` and `sw-pipeline-vitals.sh` to consume waste data without re-parsing events.

### Integration with sw-cost.sh

Add a "CONTEXT WASTE" section after the existing "EFFICIENCY" block (~line 842 of `sw-cost.sh`). Source `sw-context-waste.sh` (it has a source guard) and call an extraction function to get the overall score and top 3 patterns. Keeps the cost dashboard as the single pane of glass.

### Error Handling

- Missing `events.jsonl` → score 100 with note "No data available"
- Empty/malformed events → `jq` errors caught, skip bad lines with `jq -R 'fromjson? // empty'`
- Missing `costs.json` → skip cost-based patterns (patterns 5, 6), note in output
- Zero iterations → avoid divide-by-zero with `// 1` jq fallback
- All `jq` pipelines use `// 0`, `// empty`, or `// "unknown"` defaults

## Alternatives Considered

1. **TypeScript/Node module instead of Bash** — Pros: richer data structures, easier JSON manipulation, type safety. Cons: every other Shipwright script is Bash; introducing a Node dependency for a CLI tool breaks the convention, adds startup latency, and complicates the source-guard pattern used by `sw-cost.sh`. The `jq`-heavy approach is consistent with the 100+ existing scripts.

2. **Extend sw-self-optimize.sh instead of a new script** — Pros: avoids a new file; self-optimize already has 3 context rules at line 1190. Cons: self-optimize is 1690 lines and focused on daemon tuning, not user-facing analysis. Mixing a user CLI dashboard into an optimization engine violates single responsibility. The new script can consume self-optimize's output without coupling.

3. **Real-time in-loop analysis (hook-based)** — Pros: catches waste as it happens. Cons: adds latency to every loop iteration; the post-tool-use hook (`post-tool-use.sh`) already captures errors. A post-hoc analyzer is cheaper, non-blocking, and can analyze across multiple runs for trends.

4. **Dashboard-only (no CLI)** — Pros: richer visualization in the web UI. Cons: dashboard requires Bun, isn't available in CI, and the dashboard server at `dashboard/server.ts` already has a `/api/context-efficiency` endpoint. A CLI tool is universally accessible, scriptable, and can feed the dashboard via events.

## Implementation Plan

- **Files to create:**
  - `scripts/sw-context-waste.sh` — Main analyzer (~650 lines)
  - `scripts/sw-context-waste-test.sh` — Test suite (~350 lines)

- **Files to modify:**
  - `scripts/sw` — Add `context-waste)` case in main dispatcher (~line 350, alphabetically after `context`)
  - `scripts/sw-cost.sh` — Add "CONTEXT WASTE" section to `cost_dashboard()` after the EFFICIENCY block (~line 842), source `sw-context-waste.sh` for data functions
  - `package.json` — Add `bash scripts/sw-context-waste-test.sh &&` to `test` script, alphabetically after `sw-context-test.sh`

- **Dependencies:** None new. Requires `jq` (already a prerequisite checked by `shipwright doctor`).

- **Risk areas:**
  - **`jq` pipeline complexity** — 6 detectors parsing JSONL with joins. Mitigation: each detector is an isolated function with its own `jq` filter, individually testable.
  - **Event format assumptions** — All event values are strings in events.jsonl. Must use `tonumber` consistently. Mitigation: test with real event data from `sw-loop-test.sh` output.
  - **Cost join accuracy** — Joining `costs.json` entries with context events by stage name and time proximity. Mitigation: use stage name as primary key (exact match), timestamp as tiebreaker, not a fuzzy join.
  - **Bash 3.2 arithmetic** — Integer-only. All scoring math must use `jq` for float operations, not `$(( ))`. Mitigation: keep all scoring in `jq` expressions, pipe results out as formatted strings.
  - **Source guard interaction** — `sw-cost.sh` will source `sw-context-waste.sh`. The source guard (`if [[ "${BASH_SOURCE[0]}" == "$0" ]]`) must wrap only the CLI router, not the exported functions. Mitigation: follow the exact pattern from `sw-cost.sh:960`.

## Validation Criteria

- [ ] `shipwright context-waste show` renders a dashboard with overall score (0-100), per-stage breakdown, detected patterns, and recommendations
- [ ] `shipwright context-waste show --json` outputs valid JSON (verifiable with `| jq .`)
- [ ] `shipwright context-waste score` exits 0 and prints a single integer 0-100
- [ ] Each of the 6 waste patterns is independently triggered by synthetic test data and independently absent when conditions aren't met
- [ ] Score of 100 when events show 0% trim ratio, >50% utilization, ≤3 iterations, no pattern triggers
- [ ] Score of 0 when all penalties are maximized
- [ ] Graceful degradation: missing `events.jsonl` → score 100 + "No data"; missing `costs.json` → skip cost patterns
- [ ] `sw-cost.sh show` includes a "CONTEXT WASTE" section with score and top patterns
- [ ] `context_waste.analysis` event emitted after each analysis and parseable from `events.jsonl`
- [ ] All tests pass: `bash scripts/sw-context-waste-test.sh` exits 0 with 0 failures
- [ ] `npm test` passes with the new test suite registered
- [ ] Script is Bash 3.2 compatible: no associative arrays, no readarray, no ${var,,}
- [ ] VERSION matches `package.json` (currently 3.2.0)
