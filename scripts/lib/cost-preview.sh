#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  cost-preview.sh — Forward-looking cost estimation & budget-aware template ║
# ║  selection. Sourced by sw-cost.sh; functions are side-effect free on load. ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Public functions:
#   cp_estimate_template <template> [complexity]   -> echoes predicted USD total
#   cp_preview_one       <template> [complexity] [json:0|1]
#   cp_preview_all       [complexity] [json:0|1]
#   cp_select            [complexity] [json:0|1]   -> echoes recommended template
#
# Depends on (provided by sw-cost.sh when sourced there):
#   cost_calculate <input_tokens> <output_tokens> <model>
#   cost_remaining_budget
#   info/warn/error/success/emit_event (helpers.sh)
#   _smart_int (compat.sh)

# Idempotent source guard
if [[ -n "${_CP_LIB_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_CP_LIB_LOADED=1

CP_VERSION="3.4.0"

# Locate the repo root relative to this file so template JSON resolves
# regardless of the caller's working directory.
_CP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CP_REPO_DIR="$(cd "$_CP_LIB_DIR/../.." && pwd)"

# ─── Historical cost tracking ───────────────────────────────────────────────
# Append-only JSONL ledger of estimate/actual costs per run. Resolved at call
# time (not load time) so $HOME overrides in tests are honored.
#   {"kind":"estimate|actual","template":..,"complexity":..,"usd":..,"run_id":..,"ts":epoch}
_cp_history_file() {
    echo "${SHIPWRIGHT_COST_HISTORY:-${HOME}/.shipwright/cost-history.jsonl}"
}

# Recency half-life (days) for time-decay weighting of historical samples.
_CP_HALF_LIFE_DAYS=30
# Complexity band (±) within which historical samples are considered comparable.
_CP_COMPLEXITY_BAND=5

# Current epoch seconds. Isolated so it is the only impurity in this lib.
_cp_now() { date +%s 2>/dev/null || echo 0; }

# ─── Record a cost sample (atomic append under flock) ───────────────────────
# _cp_record <kind> <template> <complexity> <usd> [run_id]
_cp_record() {
    local kind="$1" template="$2" complexity="${3:-50}" usd="${4:-0}" run_id="${5:-}"
    local file line now
    file="$(_cp_history_file)"
    now="$(_cp_now)"
    [[ "$complexity" =~ ^[0-9]+$ ]] || complexity=50
    [[ "$usd" =~ ^[0-9]+\.?[0-9]*$ ]] || usd=0
    [[ -z "$run_id" ]] && run_id="${template}-${now}-$$"

    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    line=$(jq -cn \
        --arg kind "$kind" --arg template "$template" \
        --argjson complexity "$complexity" --arg usd "$usd" \
        --arg run_id "$run_id" --argjson ts "$now" \
        '{kind:$kind, template:$template, complexity:$complexity, usd:($usd|tonumber), run_id:$run_id, ts:$ts}' \
        2>/dev/null) || return 1

    if command -v flock >/dev/null 2>&1; then
        (
            flock -w 10 200 2>/dev/null || true
            printf '%s\n' "$line" >> "$file"
        ) 200>>"${file}.lock"
    else
        printf '%s\n' "$line" >> "$file"
    fi
    echo "$run_id"
}

# cp_record_estimate <template> <complexity> <usd> [run_id] -> echoes run_id
cp_record_estimate() { _cp_record "estimate" "$@"; }
# cp_record_actual   <template> <complexity> <usd> [run_id] -> echoes run_id
cp_record_actual()   { _cp_record "actual" "$@"; }

# ─── Time-decayed weighted median of historical actuals ─────────────────────
# cp_history_median <template> <complexity>
# Echoes the recency-weighted median USD of past *actual* runs for this template
# within ±_CP_COMPLEXITY_BAND complexity, or nothing when no samples exist.
cp_history_median() {
    local template="$1" complexity="${2:-50}"
    local file now lo hi
    file="$(_cp_history_file)"
    [[ -f "$file" ]] || return 0
    [[ "$complexity" =~ ^[0-9]+$ ]] || complexity=50
    lo=$(( complexity - _CP_COMPLEXITY_BAND ))
    hi=$(( complexity + _CP_COMPLEXITY_BAND ))
    now="$(_cp_now)"

    # Extract "usd ts" for matching actual samples, then compute a weighted
    # median in awk: weight = 2^(-age_days / half_life), median = value where
    # cumulative weight (over usd-sorted samples) first crosses half the total.
    jq -r --arg t "$template" --argjson lo "$lo" --argjson hi "$hi" \
        'select(.kind=="actual" and .template==$t and .complexity>=$lo and .complexity<=$hi)
         | "\(.usd) \(.ts)"' "$file" 2>/dev/null \
    | awk -v now="$now" -v hl="$_CP_HALF_LIFE_DAYS" '
        {
            usd=$1; ts=$2;
            age=(now-ts)/86400.0; if (age<0) age=0;
            w=exp(-0.6931471805599453*age/hl);   # 2^(-age/hl)
            n++; v[n]=usd; wt[n]=w; tot+=w;
        }
        END {
            if (n==0) exit 0;
            # insertion sort by value (n is small)
            for (i=2;i<=n;i++){ kv=v[i]; kw=wt[i]; j=i-1;
                while (j>=1 && v[j]>kv){ v[j+1]=v[j]; wt[j+1]=wt[j]; j-- }
                v[j+1]=kv; wt[j+1]=kw }
            target=tot/2.0; cum=0;
            for (i=1;i<=n;i++){ cum+=wt[i]; if (cum>=target){ printf "%.4f", v[i]; exit 0 } }
            printf "%.4f", v[n];
        }'
}

# ─── Blend a static estimate with historical data ──────────────────────────
# _cp_blend <template> <complexity> <static_usd> -> echoes blended USD (4dp)
# Weight on history grows with sample count, capped; zero samples => pure static.
_cp_blend() {
    local template="$1" complexity="$2" static="$3"
    local median count file lo hi
    median="$(cp_history_median "$template" "$complexity")"
    if [[ -z "$median" ]]; then
        echo "$static"
        return 0
    fi
    file="$(_cp_history_file)"
    [[ "$complexity" =~ ^[0-9]+$ ]] || complexity=50
    lo=$(( complexity - _CP_COMPLEXITY_BAND ))
    hi=$(( complexity + _CP_COMPLEXITY_BAND ))
    count=$(jq -r --arg t "$template" --argjson lo "$lo" --argjson hi "$hi" \
        'select(.kind=="actual" and .template==$t and .complexity>=$lo and .complexity<=$hi)
         | .usd' "$file" 2>/dev/null | wc -l | tr -d ' ')
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    awk -v s="$static" -v m="$median" -v n="$count" 'BEGIN {
        c = (n>10)?10:n;
        wh = c/(c+5.0);          # history weight, saturating toward ~0.67
        printf "%.4f", wh*m + (1.0-wh)*s;
    }'
}

# Capability ranking, most → least capable. Used by cp_select to pick the
# richest template whose predicted cost fits the budget ceiling.
_CP_CAPABILITY_ORDER="full enterprise deployed autonomous tdd standard cost-aware hotfix fast"

# ─── Per-stage token model ──────────────────────────────────────────────────
# Estimated total tokens (input+output) a stage typically consumes. Mirrors the
# map in sw-model-router.sh:estimate_cost so there is a single source of truth.
# Unknown stages fall back to 5000.
_cp_stage_tokens() {
    case "${1:-}" in
        intake)             echo 5000 ;;
        plan)               echo 50000 ;;
        design)             echo 50000 ;;
        spec_generation)    echo 30000 ;;
        build)              echo 100000 ;;
        test)               echo 30000 ;;
        review)             echo 20000 ;;
        spec_verification)  echo 20000 ;;
        compound_quality)   echo 40000 ;;
        pr)                 echo 10000 ;;
        merge)              echo 5000 ;;
        deploy)             echo 5000 ;;
        validate)           echo 5000 ;;
        monitor)            echo 5000 ;;
        *)                  echo 5000 ;;
    esac
}

# ─── Resolve the model for a stage ──────────────────────────────────────────
# Layered fallback: stage config.model → template defaults.model → opus.
# _cp_stage_model <template_json_file> <stage_id>
_cp_stage_model() {
    local file="$1" stage="$2" model
    model=$(jq -r --arg s "$stage" \
        '(.stages[] | select(.id==$s) | .config.model) // empty' \
        "$file" 2>/dev/null || true)
    if [[ -z "$model" || "$model" == "null" ]]; then
        model=$(jq -r '.defaults.model // empty' "$file" 2>/dev/null || true)
    fi
    if [[ -z "$model" || "$model" == "null" ]]; then
        model="opus"
    fi
    echo "$model"
}

# Resolve a template name to its JSON file path. Echoes path, returns 1 if absent.
_cp_template_file() {
    local template="$1"
    local file="$_CP_REPO_DIR/templates/pipelines/${template}.json"
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    echo "$file"
}

# Complexity → token scale factor. complexity 50 is the baseline (factor 1.0);
# higher complexity scales token usage up linearly. Echoes a decimal factor.
_cp_complexity_factor() {
    local complexity="${1:-50}"
    if [[ ! "$complexity" =~ ^[0-9]+$ ]] || [[ "$complexity" -le 0 ]]; then
        complexity=50
    fi
    awk -v c="$complexity" 'BEGIN { printf "%.4f", c / 50.0 }'
}

# ─── Estimate total predicted cost for a template ───────────────────────────
# cp_estimate_template <template> [complexity]
# Echoes the numeric USD total (4dp). Pure compute, no formatting.
cp_estimate_template() {
    local template="${1:-standard}"
    local complexity="${2:-50}"
    local file
    if ! file=$(_cp_template_file "$template"); then
        error "Template not found: $template (expected templates/pipelines/${template}.json)" >&2
        return 1
    fi

    local factor
    factor=$(_cp_complexity_factor "$complexity")

    local total="0"
    local stage tokens model adj_tokens input_tokens output_tokens stage_cost
    while IFS= read -r stage; do
        [[ -z "$stage" ]] && continue
        tokens=$(_cp_stage_tokens "$stage")
        model=$(_cp_stage_model "$file" "$stage")
        # Apply complexity scaling, then split 70% input / 30% output.
        adj_tokens=$(awk -v t="$tokens" -v f="$factor" 'BEGIN { printf "%d", t * f }')
        input_tokens=$(( adj_tokens * 7 / 10 ))
        output_tokens=$(( adj_tokens * 3 / 10 ))
        stage_cost=$(cost_calculate "$input_tokens" "$output_tokens" "$model")
        total=$(awk -v a="$total" -v b="$stage_cost" 'BEGIN { printf "%.4f", a + b }')
    done < <(jq -r '.stages[] | select(.enabled==true) | .id' "$file" 2>/dev/null)

    # Blend with historical actuals when available; pure static otherwise.
    _cp_blend "$template" "$complexity" "$total"
}

# ─── Preview a single template (human table or JSON) ────────────────────────
# cp_preview_one <template> [complexity] [json:0|1]
cp_preview_one() {
    local template="${1:-standard}"
    local complexity="${2:-50}"
    local json="${3:-0}"
    local file
    if ! file=$(_cp_template_file "$template"); then
        error "Template not found: $template"
        return 1
    fi

    local factor
    factor=$(_cp_complexity_factor "$complexity")
    local total
    total=$(cp_estimate_template "$template" "$complexity") || return 1

    if [[ "$json" == "1" ]]; then
        local stages_json="[]"
        local stage tokens model adj_tokens input_tokens output_tokens stage_cost
        while IFS= read -r stage; do
            [[ -z "$stage" ]] && continue
            tokens=$(_cp_stage_tokens "$stage")
            model=$(_cp_stage_model "$file" "$stage")
            adj_tokens=$(awk -v t="$tokens" -v f="$factor" 'BEGIN { printf "%d", t * f }')
            input_tokens=$(( adj_tokens * 7 / 10 ))
            output_tokens=$(( adj_tokens * 3 / 10 ))
            stage_cost=$(cost_calculate "$input_tokens" "$output_tokens" "$model")
            stages_json=$(jq -c \
                --arg stage "$stage" --arg model "$model" \
                --argjson it "$input_tokens" --argjson ot "$output_tokens" \
                --arg cost "$stage_cost" \
                '. + [{stage:$stage, model:$model, input_tokens:$it, output_tokens:$ot, cost_usd:($cost|tonumber)}]' \
                <<<"$stages_json")
        done < <(jq -r '.stages[] | select(.enabled==true) | .id' "$file" 2>/dev/null)

        jq -n \
            --arg template "$template" \
            --argjson complexity "$complexity" \
            --arg total "$total" \
            --argjson stages "$stages_json" \
            '{template:$template, complexity:$complexity, total_usd:($total|tonumber), stages:$stages}'
        return 0
    fi

    echo ""
    info "Cost preview: template '$template' (complexity $complexity)"
    echo ""
    printf "%-20s %-10s %-14s %-14s %-10s\n" "Stage" "Model" "Input" "Output" "Cost"
    echo "──────────────────────────────────────────────────────────────────────"
    local stage tokens model adj_tokens input_tokens output_tokens stage_cost
    while IFS= read -r stage; do
        [[ -z "$stage" ]] && continue
        tokens=$(_cp_stage_tokens "$stage")
        model=$(_cp_stage_model "$file" "$stage")
        adj_tokens=$(awk -v t="$tokens" -v f="$factor" 'BEGIN { printf "%d", t * f }')
        input_tokens=$(( adj_tokens * 7 / 10 ))
        output_tokens=$(( adj_tokens * 3 / 10 ))
        stage_cost=$(cost_calculate "$input_tokens" "$output_tokens" "$model")
        printf "%-20s %-10s %-14d %-14d \$%-9s\n" "$stage" "$model" "$input_tokens" "$output_tokens" "$stage_cost"
    done < <(jq -r '.stages[] | select(.enabled==true) | .id' "$file" 2>/dev/null)
    echo "──────────────────────────────────────────────────────────────────────"
    printf "%-60s \$%-9s\n" "Total" "$total"
    echo ""
}

# ─── Preview every template, sorted ascending by cost ───────────────────────
# cp_preview_all [complexity] [json:0|1]
cp_preview_all() {
    local complexity="${1:-50}"
    local json="${2:-0}"
    local dir="$_CP_REPO_DIR/templates/pipelines"

    # Build "cost\ttemplate" lines, skipping unparseable files.
    local rows=""
    local f name cost
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        name="$(basename "$f" .json)"
        if ! jq -e . "$f" >/dev/null 2>&1; then
            warn "Skipping unparseable template: $name" >&2
            continue
        fi
        cost=$(cp_estimate_template "$name" "$complexity") || continue
        rows="${rows}${cost}	${name}
"
    done

    # Sort ascending by numeric cost.
    local sorted
    sorted=$(printf '%s' "$rows" | sort -t'	' -k1 -g)

    if [[ "$json" == "1" ]]; then
        local arr="[]"
        while IFS=$'\t' read -r cost name; do
            [[ -z "$name" ]] && continue
            arr=$(jq -c --arg t "$name" --arg c "$cost" \
                '. + [{template:$t, total_usd:($c|tonumber)}]' <<<"$arr")
        done <<<"$sorted"
        jq -n --argjson complexity "$complexity" --argjson templates "$arr" \
            '{complexity:$complexity, templates:$templates}'
        return 0
    fi

    echo ""
    info "Cost preview for all templates (complexity $complexity)"
    echo ""
    printf "%-20s %-10s\n" "Template" "Est. Cost"
    echo "────────────────────────────────"
    while IFS=$'\t' read -r cost name; do
        [[ -z "$name" ]] && continue
        printf "%-20s \$%-9s\n" "$name" "$cost"
    done <<<"$sorted"
    echo ""
}

# ─── Budget-aware template selection ────────────────────────────────────────
# cp_select [complexity] [json:0|1]
# Echoes the recommended template name on stdout (machine-consumable).
cp_select() {
    local complexity="${1:-50}"
    local json="${2:-0}"
    local default_template="standard"

    local remaining
    remaining=$(cost_remaining_budget 2>/dev/null | tail -n1 || echo "unlimited")

    local selected reason est ceiling
    if [[ "$remaining" == "unlimited" || -z "$remaining" || ! "$remaining" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        selected="$default_template"
        reason="budget unlimited — default template"
        est=$(cp_estimate_template "$selected" "$complexity" 2>/dev/null || echo "0")
        ceiling="unlimited"
    else
        # Spend at most SAFETY_FRACTION% of the remaining budget.
        local fraction
        fraction=$(_smart_int "budget_select_fraction" 90 2>/dev/null || echo 90)
        ceiling=$(awk -v r="$remaining" -v f="$fraction" 'BEGIN { printf "%.4f", r * f / 100.0 }')

        selected=""
        local t cost
        for t in $_CP_CAPABILITY_ORDER; do
            _cp_template_file "$t" >/dev/null 2>&1 || continue
            cost=$(cp_estimate_template "$t" "$complexity" 2>/dev/null || continue)
            if awk -v c="$cost" -v cap="$ceiling" 'BEGIN { exit !(c <= cap) }'; then
                selected="$t"
                est="$cost"
                reason="most capable template within budget ceiling \$$ceiling"
                break
            fi
        done

        if [[ -z "$selected" ]]; then
            # Nothing fits — fall back to the cheapest template and warn.
            local cheapest_line
            cheapest_line=$(cp_preview_all "$complexity" 1 2>/dev/null \
                | jq -r '.templates[0] | "\(.template) \(.total_usd)"' 2>/dev/null || true)
            selected="${cheapest_line%% *}"
            est="${cheapest_line##* }"
            [[ -z "$selected" || "$selected" == "null" ]] && selected="fast" && est="0"
            reason="no template fits budget ceiling \$$ceiling — using cheapest"
            warn "No pipeline template fits the remaining budget; using cheapest ('$selected')." >&2
        fi
    fi

    emit_event "cost.template_selected" \
        "template=$selected" "estimated_usd=$est" \
        "remaining=$remaining" "complexity=$complexity" || true

    if [[ "$json" == "1" ]]; then
        jq -n \
            --arg template "$selected" \
            --arg est "$est" \
            --arg remaining "$remaining" \
            --arg ceiling "$ceiling" \
            --argjson complexity "$complexity" \
            --arg reason "$reason" \
            '{template:$template, estimated_usd:($est|tonumber), remaining:$remaining, ceiling:$ceiling, complexity:$complexity, reason:$reason}'
    else
        echo "$selected"
    fi
}

# ─── Estimate-vs-actual accuracy report ─────────────────────────────────────
# cp_accuracy [json:0|1]
# Pairs estimate/actual samples by run_id and reports mean absolute percentage
# error (MAPE), sample count, and per-template breakdown.
cp_accuracy() {
    local json="${1:-0}"
    local file
    file="$(_cp_history_file)"

    if [[ ! -f "$file" ]]; then
        if [[ "$json" == "1" ]]; then
            jq -n '{samples:0, mape:null, templates:[]}'
        else
            info "No cost history yet — run pipelines to accumulate estimate vs actual data."
        fi
        return 0
    fi

    # Build paired records {template, estimated, actual} joined on run_id, then
    # compute MAPE overall and per template. Pure jq; no shell math.
    local report
    report=$(jq -s '
        (map(select(.kind=="estimate")) | group_by(.run_id)
            | map({key:.[0].run_id, est:(.[-1].usd), template:.[-1].template})) as $ests
        | (map(select(.kind=="actual")) | group_by(.run_id)
            | map({key:.[0].run_id, act:(.[-1].usd)})) as $acts
        | ($acts | map({(.key): .act}) | add // {}) as $am
        | [ $ests[] | select($am[.key] != null and $am[.key] > 0)
            | {template, est, act:$am[.key],
               ape: (((($am[.key]) - .est) | fabs) / ($am[.key]) * 100.0) } ] as $pairs
        | {
            samples: ($pairs | length),
            mape: (if ($pairs|length)>0 then (($pairs | map(.ape) | add) / ($pairs|length)) else null end),
            templates: ($pairs | group_by(.template) | map({
                template: .[0].template,
                samples: length,
                mape: ((map(.ape) | add) / length)
            }))
          }' "$file" 2>/dev/null) || report='{"samples":0,"mape":null,"templates":[]}'

    if [[ "$json" == "1" ]]; then
        echo "$report"
        return 0
    fi

    local samples mape
    samples=$(echo "$report" | jq -r '.samples')
    if [[ "$samples" == "0" ]]; then
        info "No matched estimate/actual pairs yet."
        return 0
    fi
    mape=$(echo "$report" | jq -r 'if .mape==null then "n/a" else (.mape*100|round/100|tostring) end')

    echo ""
    info "Cost estimate accuracy ($samples paired runs)"
    echo ""
    printf "%-20s %-10s %-12s\n" "Template" "Samples" "MAPE %"
    echo "──────────────────────────────────────────────"
    echo "$report" | jq -r '.templates[] | "\(.template)\t\(.samples)\t\(.mape*100|round/100)"' \
        | while IFS=$'\t' read -r t n e; do
            printf "%-20s %-10s %-12s\n" "$t" "$n" "$e"
        done
    echo "──────────────────────────────────────────────"
    printf "%-20s %-10s %-12s\n" "OVERALL" "$samples" "$mape"
    echo ""
}
