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

CP_VERSION="3.3.0"

# Locate the repo root relative to this file so template JSON resolves
# regardless of the caller's working directory.
_CP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CP_REPO_DIR="$(cd "$_CP_LIB_DIR/../.." && pwd)"

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

    echo "$total"
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
