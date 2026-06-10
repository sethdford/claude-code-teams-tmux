#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#   shipwright cost-attribution — Per-pipeline cost attribution
#   Aggregates recorded cost entries (costs.json) into a per-pipeline
#   artifact (.claude/pipeline-artifacts/cost.json) with stage-level
#   breakdown, model usage distribution, and budget forecasting.
#
#   Source this from sw-cost.sh / sw-pipeline.sh:
#     source "$SCRIPT_DIR/lib/cost-attribution.sh"
#
#   Bash 3.2 compatible — no associative arrays, no readarray.
# ═══════════════════════════════════════════════════════════════════

# ─── Double-source guard ─────────────────────────────────────────
[[ -n "${_SW_COST_ATTRIBUTION_LOADED:-}" ]] && return 0
_SW_COST_ATTRIBUTION_LOADED=1

# Schema version for the cost artifact — bump on breaking changes.
COST_ARTIFACT_SCHEMA_VERSION=1

# Source of recorded cost entries (written by cost_record in sw-cost.sh).
# Overridable for tests.
COST_FILE="${COST_FILE:-${HOME}/.shipwright/costs.json}"

# Where the per-pipeline artifact is written.
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"

# Fallback output helpers when helpers.sh is not sourced (test env).
if ! type info >/dev/null 2>&1; then
    info()    { echo "▸ $*"; }
    success() { echo "✓ $*"; }
    warn()    { echo "⚠ $*"; }
    error()   { echo "✗ $*" >&2; }
fi
if ! type now_iso >/dev/null 2>&1; then
    now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
fi

# ─── Aggregation ─────────────────────────────────────────────────
# cost_attribution_aggregate <issue> [cost_file]
# Reads recorded cost entries for the given issue and emits a per-pipeline
# cost JSON object on stdout (matching the cost artifact schema). When the
# cost file is missing or has no matching entries, emits a zeroed object so
# callers always get valid JSON.
cost_attribution_aggregate() {
    local issue="${1:-}"
    local cost_file="${2:-$COST_FILE}"
    local template="${COST_TEMPLATE:-${PIPELINE_TEMPLATE:-}}"
    local generated_at
    generated_at="$(now_iso)"

    if [[ -z "$issue" ]]; then
        error "cost_attribution_aggregate: issue is required"
        return 1
    fi

    # Normalize issue: strip a leading '#' so "#613" and "613" match.
    local issue_norm="${issue#\#}"

    if [[ ! -f "$cost_file" ]]; then
        _cost_attribution_empty "$issue_norm" "$template" "$generated_at"
        return 0
    fi

    # Aggregate with jq: filter entries by issue, group by stage and by model.
    # Model labels are normalized to opus/sonnet/haiku families.
    jq -n \
        --slurpfile data "$cost_file" \
        --arg issue "$issue_norm" \
        --arg template "$template" \
        --arg generated_at "$generated_at" \
        --argjson schema "$COST_ARTIFACT_SCHEMA_VERSION" '
        ($data[0].entries // [])
        | map(select((.issue // "" | sub("^#"; "")) == $issue))
        as $entries
        | ($entries | map(.cost_usd // 0) | add // 0) as $total_cost
        | {
            schema_version: $schema,
            issue: $issue,
            template: $template,
            generated_at: $generated_at,
            total_cost_usd: ($total_cost | (. * 10000 | round) / 10000),
            total_input_tokens: ($entries | map(.input_tokens // 0) | add // 0),
            total_output_tokens: ($entries | map(.output_tokens // 0) | add // 0),
            call_count: ($entries | length),
            stages: (
                $entries
                | group_by(.stage // "unknown")
                | map({
                    key: (.[0].stage // "unknown"),
                    value: {
                        cost_usd: (map(.cost_usd // 0) | add | (. * 10000 | round) / 10000),
                        input_tokens: (map(.input_tokens // 0) | add),
                        output_tokens: (map(.output_tokens // 0) | add),
                        calls: length
                    }
                })
                | from_entries
            ),
            models: (
                $entries
                | map(. + {_family: (
                    (.model // "unknown")
                    | if test("opus") then "opus"
                      elif test("sonnet") then "sonnet"
                      elif test("haiku") then "haiku"
                      else . end
                  )})
                | group_by(._family)
                | map({
                    key: .[0]._family,
                    value: {
                        cost_usd: (map(.cost_usd // 0) | add | (. * 10000 | round) / 10000),
                        calls: length,
                        pct: (
                            if $total_cost > 0
                            then ((map(.cost_usd // 0) | add) / $total_cost * 1000 | round) / 10
                            else 0 end
                        )
                    }
                })
                | from_entries
            )
        }' 2>/dev/null || {
        _cost_attribution_empty "$issue_norm" "$template" "$generated_at"
        return 0
    }
}

# _cost_attribution_empty <issue> <template> <generated_at>
# Emits a zeroed cost object — used when no data is available.
_cost_attribution_empty() {
    jq -n \
        --arg issue "$1" \
        --arg template "$2" \
        --arg generated_at "$3" \
        --argjson schema "$COST_ARTIFACT_SCHEMA_VERSION" '{
            schema_version: $schema,
            issue: $issue,
            template: $template,
            generated_at: $generated_at,
            total_cost_usd: 0,
            total_input_tokens: 0,
            total_output_tokens: 0,
            call_count: 0,
            stages: {},
            models: {}
        }'
}

# ─── Artifact Writer ─────────────────────────────────────────────
# write_cost_artifact <issue> [artifacts_dir]
# Aggregates costs for the pipeline and writes them atomically to
# <artifacts_dir>/cost.json. Returns 0 on success, 1 on failure.
write_cost_artifact() {
    local issue="${1:-}"
    local artifacts_dir="${2:-$ARTIFACTS_DIR}"

    if [[ -z "$issue" ]]; then
        error "write_cost_artifact: issue is required"
        return 1
    fi

    mkdir -p "$artifacts_dir" 2>/dev/null || {
        error "write_cost_artifact: cannot create $artifacts_dir"
        return 1
    }

    local out="${artifacts_dir}/cost.json"
    local tmp
    tmp=$(mktemp "${out}.tmp.XXXXXX") || {
        error "write_cost_artifact: mktemp failed"
        return 1
    }

    if ! cost_attribution_aggregate "$issue" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        error "write_cost_artifact: aggregation failed"
        return 1
    fi

    # Validate that we produced parseable JSON before swapping in.
    if ! jq empty "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        error "write_cost_artifact: produced invalid JSON"
        return 1
    fi

    mv "$tmp" "$out" || {
        rm -f "$tmp"
        error "write_cost_artifact: failed to write $out"
        return 1
    }

    type emit_event >/dev/null 2>&1 && emit_event "cost.artifact_written" \
        "issue=${issue}" \
        "total_cost_usd=$(jq -r '.total_cost_usd' "$out" 2>/dev/null || echo 0)"

    return 0
}

# ─── Budget Forecasting ──────────────────────────────────────────
# cost_attribution_forecast <remaining_budget_usd> [cost_file]
# Estimates how many more pipelines fit in the remaining budget based on
# the historical average per-pipeline cost. Emits a JSON forecast object.
# A pipeline is identified by a distinct non-empty issue in the cost file.
cost_attribution_forecast() {
    local remaining="${1:-0}"
    local cost_file="${2:-$COST_FILE}"

    if [[ ! -f "$cost_file" ]]; then
        jq -n --argjson rem "$(_cost_num "$remaining")" '{
            remaining_budget_usd: $rem,
            avg_pipeline_cost_usd: 0,
            pipelines_completed: 0,
            pipelines_remaining: null,
            note: "no cost history available"
        }'
        return 0
    fi

    jq -n \
        --slurpfile data "$cost_file" \
        --argjson rem "$(_cost_num "$remaining")" '
        ($data[0].entries // [])
        | map(select((.issue // "") != ""))
        as $entries
        | (
            $entries
            | group_by(.issue // "")
            | map({issue: .[0].issue, cost: (map(.cost_usd // 0) | add)})
          ) as $pipelines
        | ($pipelines | length) as $n
        | (if $n > 0 then ($pipelines | map(.cost) | add) / $n else 0 end) as $avg
        | {
            remaining_budget_usd: $rem,
            avg_pipeline_cost_usd: (($avg * 10000 | round) / 10000),
            pipelines_completed: $n,
            pipelines_remaining: (
                # epsilon guards against IEEE rounding (e.g. 1.5/0.15 = 9.999…)
                if $avg > 0 then (($rem / $avg) + 0.0000001 | floor) else null end
            )
        }' 2>/dev/null || {
        jq -n --argjson rem "$(_cost_num "$remaining")" '{
            remaining_budget_usd: $rem,
            avg_pipeline_cost_usd: 0,
            pipelines_completed: 0,
            pipelines_remaining: null,
            note: "forecast computation failed"
        }'
    }
}

# _cost_num <value> — coerce a possibly-non-numeric value to a JSON number.
# "unlimited" and empty/garbage become 0.
_cost_num() {
    local v="${1:-0}"
    case "$v" in
        ''|*[!0-9.]*) echo 0 ;;
        *) echo "$v" ;;
    esac
}
