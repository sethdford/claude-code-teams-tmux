# pipeline-feasibility.sh — Pre-flight issue feasibility validator
#
# Scores an issue 0-100 across 8 deterministic heuristics and gates the
# pipeline before downstream stages consume budget on doomed work.

[[ -n "${_PIPELINE_FEASIBILITY_LOADED:-}" ]] && return 0
_PIPELINE_FEASIBILITY_LOADED=1

VERSION="3.3.0"

_feas_clamp() {
    local n="$1" lo="${2:-0}" hi="${3:-100}"
    [[ "$n" =~ ^-?[0-9]+$ ]] || n=0
    (( n < lo )) && n=$lo
    (( n > hi )) && n=$hi
    echo "$n"
}

# ─── Heuristics — each emits "<deduction>\t<reason>" on stdout ──────────

_feas_check_body_length() {
    local body="${1:-}"
    local len=${#body}
    if   (( len < 20  )); then printf -- "-25\tBody under 20 chars (vague/empty)\n"
    elif (( len < 60  )); then printf -- "-15\tBody under 60 chars\n"
    elif (( len < 120 )); then printf -- "-5\tBody under 120 chars\n"
    else printf "0\tBody length ok (%d chars)\n" "$len"
    fi
}

_feas_check_acceptance_criteria() {
    local path="${1:-}"
    if [[ ! -f "$path" ]]; then
        printf -- "-15\tNo acceptance-criteria.json (intent analysis skipped)\n"
        return
    fi
    local count
    count=$(jq -r '(.criteria // []) | length' "$path" 2>/dev/null || echo 0)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    if   (( count == 0 )); then printf -- "-15\tZero acceptance criteria\n"
    elif (( count < 2 )); then printf -- "-5\tOnly %d acceptance criterion\n" "$count"
    else printf "0\t%d acceptance criteria\n" "$count"
    fi
}

_feas_check_conflicting_labels() {
    local labels="${1:-}"
    [[ -z "$labels" ]] && { printf "0\tNo labels to conflict\n"; return; }
    local has_feature=0 has_revert=0 has_hotfix=0 has_wontfix=0 has_blocked=0
    case ",$labels," in
        *,feature,*|*,enhancement,*|*,feat,*) has_feature=1 ;;
    esac
    case ",$labels," in *,revert,*|*,rollback,*) has_revert=1 ;; esac
    case ",$labels," in *,hotfix,*) has_hotfix=1 ;; esac
    case ",$labels," in *,wontfix,*|*,invalid,*|*,duplicate,*) has_wontfix=1 ;; esac
    case ",$labels," in *,blocked,*|*,on-hold,*) has_blocked=1 ;; esac

    if (( has_wontfix )); then
        printf -- "-40\tLabel marks issue as wontfix/invalid/duplicate\n"; return
    fi
    if (( has_blocked )); then
        printf -- "-30\tLabel marks issue as blocked/on-hold\n"; return
    fi
    if (( has_feature && has_revert )); then
        printf -- "-25\tConflicting labels: feature + revert\n"; return
    fi
    if (( has_feature && has_hotfix )); then
        printf -- "-15\tConflicting labels: feature + hotfix\n"; return
    fi
    printf "0\tLabels coherent\n"
}

_feas_check_scope() {
    local spec="${1:-}"
    if [[ ! -f "$spec" ]]; then
        printf "0\tNo spec — scope check skipped\n"; return
    fi
    local n
    n=$(jq -r '(.affected_files // []) | length' "$spec" 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    if   (( n > 100 )); then printf -- "-30\tHuge scope: %d affected files\n" "$n"
    elif (( n > 50  )); then printf -- "-15\tLarge scope: %d affected files\n" "$n"
    elif (( n > 20  )); then printf -- "-5\tModerate scope: %d affected files\n" "$n"
    else printf "0\tScope ok (%d files)\n" "$n"
    fi
}

_feas_check_architecture_violation() {
    local body="${1:-}"
    [[ -z "$body" ]] && { printf "0\tEmpty body — arch check skipped\n"; return; }
    local bad=""
    # Bash 3.2 incompatibility hints
    if   [[ "$body" == *"declare -A"* ]]; then bad="declare -A (bash 3.2 incompatible)"
    elif [[ "$body" == *"readarray"*  ]]; then bad="readarray (bash 3.2 incompatible)"
    elif [[ "$body" == *"force push"* || "$body" == *"force-push"* ]]; then bad="force push requested"
    elif [[ "$body" == *"skip hook"*  || "$body" == *"bypass hook"* ]]; then bad="hook bypass requested"
    fi
    if [[ -n "$bad" ]]; then
        printf -- "-15\tArchitecture violation hint: %s\n" "$bad"
    else
        printf "0\tNo architecture violations detected\n"
    fi
}

_feas_check_memory_similarity() {
    local body="${1:-}"
    local mem_dir="${2:-${HOME}/.shipwright/memory}"
    [[ -z "$body" || ${#body} -lt 20 ]] && { printf "0\tBody too short for similarity\n"; return; }
    local fails=""
    if [[ -d "$mem_dir" ]]; then
        fails=$(find "$mem_dir" -maxdepth 3 -name failures.json -print 2>/dev/null | head -1 || true)
    fi
    [[ -z "$fails" || ! -f "$fails" ]] && { printf "0\tNo memory failures to compare\n"; return; }

    local tokens
    tokens=$(echo "$body" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '\n' | awk 'length($0)>=4' | sort -u)
    [[ -z "$tokens" ]] && { printf "0\tNo comparable tokens\n"; return; }

    local best=0 best_id=""
    while IFS=$'\t' read -r fid ftext; do
        [[ -z "$ftext" ]] && continue
        local ftokens
        ftokens=$(echo "$ftext" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '\n' | awk 'length($0)>=4' | sort -u)
        [[ -z "$ftokens" ]] && continue
        local inter union pct
        inter=$(comm -12 <(echo "$tokens") <(echo "$ftokens") | wc -l | tr -d ' ')
        union=$(echo "$tokens"$'\n'"$ftokens" | sort -u | wc -l | tr -d ' ')
        (( union == 0 )) && continue
        pct=$(( inter * 100 / union ))
        if (( pct > best )); then best=$pct; best_id="$fid"; fi
    done < <(jq -r '(. // []) | .[] | [(.issue // .id // "?"), ((.goal // .summary // .error // ""))] | @tsv' "$fails" 2>/dev/null || true)

    if   (( best >= 70 )); then printf -- "-20\tJaccard %d%% with prior failure %s\n" "$best" "$best_id"
    elif (( best >= 50 )); then printf -- "-10\tJaccard %d%% with prior failure %s\n" "$best" "$best_id"
    else printf "0\tNo close prior failure (best %d%%)\n" "$best"
    fi
}

_feas_check_budget() {
    local budget_file="${HOME}/.shipwright/budget.json"
    [[ ! -f "$budget_file" ]] && { printf "0\tNo budget configured\n"; return; }
    local remaining
    remaining=$(jq -r '.remaining // .daily_remaining // empty' "$budget_file" 2>/dev/null || true)
    [[ -z "$remaining" || "$remaining" == "null" ]] && { printf "0\tBudget remaining unknown\n"; return; }
    local rem_int
    rem_int=$(printf '%.0f' "$remaining" 2>/dev/null || echo 0)
    if   (( rem_int <= 0 )); then printf -- "-25\tBudget exhausted (\$%s remaining)\n" "$remaining"
    elif (( rem_int < 5 ));  then printf -- "-10\tBudget low (\$%s remaining)\n" "$remaining"
    else printf "0\tBudget ok (\$%s remaining)\n" "$remaining"
    fi
}

_feas_check_vagueness_terms() {
    local body="${1:-}"
    local lower
    lower=$(echo "$body" | tr '[:upper:]' '[:lower:]')
    local hits=0 found=""
    for term in "improve" "better" "optimize" "refactor" "cleanup" "tbd" "todo"; do
        case " $lower " in
            *" $term "*|*" $term."*|*" $term,"*)
                hits=$(( hits + 1 )); found="${found}${found:+, }${term}" ;;
        esac
    done
    local has_number=0
    case "$lower" in *[0-9]*) has_number=1 ;; esac

    if (( hits >= 2 && has_number == 0 )); then
        printf -- "-10\tVague terms w/o metric: %s\n" "$found"
    elif (( hits >= 1 && has_number == 0 )); then
        printf -- "-5\tVague term w/o metric: %s\n" "$found"
    else
        printf "0\tNo unqualified vague terms\n"
    fi
}

_feas_apply_label_bonuses() {
    local labels="${1:-}"
    local bonus=0 reasons=""
    case ",$labels," in
        *,hotfix,*)  bonus=$(( bonus + 25 )); reasons="${reasons}${reasons:+, }hotfix" ;;
    esac
    case ",$labels," in
        *,typo,*|*,docs,*|*,documentation,*)
            bonus=$(( bonus + 15 )); reasons="${reasons}${reasons:+, }docs/typo" ;;
    esac
    if (( bonus > 0 )); then
        printf "+%d\tBonus: %s\n" "$bonus" "$reasons"
    else
        printf "0\tNo label bonus\n"
    fi
}

# ─── Scoring ─────────────────────────────────────────────────────────────
feasibility_score() {
    local intake="${1:-}"
    local spec="${2:-}"

    local body="" labels="" criteria_path=""
    if [[ -f "$intake" ]]; then
        body=$(jq -r '.body // ""' "$intake" 2>/dev/null || echo "")
        labels=$(jq -r '.labels // ""' "$intake" 2>/dev/null || echo "")
    fi
    if [[ -n "$intake" ]]; then
        criteria_path="$(dirname "$intake")/acceptance-criteria.json"
    fi

    local checks_json="[]"
    local total=0

    _feas_run_check() {
        local name="$1" line="$2"
        local ded reason n
        ded=$(printf '%s' "$line" | cut -f1)
        reason=$(printf '%s' "$line" | cut -f2-)
        n="${ded#+}"
        [[ "$n" =~ ^-?[0-9]+$ ]] || n=0
        total=$(( total + n ))
        checks_json=$(echo "$checks_json" | jq \
            --arg name "$name" --argjson d "$n" --arg r "$reason" \
            '. + [{"name":$name,"deduction":$d,"reason":$r}]' 2>/dev/null || echo "$checks_json")
    }

    _feas_run_check "body_length"            "$(_feas_check_body_length "$body")"
    _feas_run_check "acceptance_criteria"    "$(_feas_check_acceptance_criteria "$criteria_path")"
    _feas_run_check "conflicting_labels"     "$(_feas_check_conflicting_labels "$labels")"
    _feas_run_check "scope"                  "$(_feas_check_scope "$spec")"
    _feas_run_check "architecture_violation" "$(_feas_check_architecture_violation "$body")"
    _feas_run_check "memory_similarity"      "$(_feas_check_memory_similarity "$body")"
    _feas_run_check "budget"                 "$(_feas_check_budget)"
    _feas_run_check "vagueness_terms"        "$(_feas_check_vagueness_terms "$body")"
    _feas_run_check "label_bonus"            "$(_feas_apply_label_bonuses "$labels")"

    local score
    score=$(_feas_clamp $(( 100 + total )) 0 100)

    local min_score
    if type _smart_int >/dev/null 2>&1; then
        min_score=$(_smart_int "feasibility.min_score" 40 2>/dev/null || echo 40)
    else
        min_score="${SW_FEASIBILITY_MIN_SCORE:-40}"
    fi
    [[ "$min_score" =~ ^[0-9]+$ ]] || min_score=40

    local verdict
    if   (( score < min_score )); then verdict="BLOCK"
    elif (( score < min_score + 20 )); then verdict="WARN"
    else verdict="PASS"
    fi

    jq -n \
        --argjson score "$score" \
        --arg verdict "$verdict" \
        --argjson min_score "$min_score" \
        --argjson checks "$checks_json" \
        '{score:$score, verdict:$verdict, min_score:$min_score, checks:$checks}'
}

# ─── Markdown report ─────────────────────────────────────────────────────
feasibility_report() {
    local score_json="${1:-}"
    local out_md="${2:-}"
    [[ -z "$out_md" ]] && return 1

    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/feas-report.XXXXXX")

    if [[ -f "$score_json" ]] && jq empty "$score_json" 2>/dev/null; then
        local score verdict min_score
        score=$(jq -r '.score' "$score_json")
        verdict=$(jq -r '.verdict' "$score_json")
        min_score=$(jq -r '.min_score' "$score_json")

        {
            echo "# Pre-Flight Feasibility Report"
            echo ""
            echo "- **Verdict**: \`${verdict}\`"
            echo "- **Score**: ${score}/100  (threshold: ${min_score})"
            echo ""
            echo "## Per-Check Breakdown"
            echo ""
            echo "| Check | Delta | Reason |"
            echo "|---|---:|---|"
            jq -r '.checks[] | "| \(.name) | \(.deduction) | \(.reason) |"' "$score_json"
            echo ""
            if [[ "$verdict" == "BLOCK" ]]; then
                echo "## Remediation"
                echo ""
                echo "Score below threshold (${min_score}). Address negative checks above and re-run."
            fi
        } > "$tmp"
    else
        printf "# Feasibility Report\n\n*Degraded: score JSON unreadable.*\n" > "$tmp"
    fi

    mkdir -p "$(dirname "$out_md")" 2>/dev/null || true
    mv "$tmp" "$out_md"
}

# ─── Public Gate ─────────────────────────────────────────────────────────
feasibility_gate() {
    local artifacts_dir="${1:-${ARTIFACTS_DIR:-.claude/pipeline-artifacts}}"

    if [[ "${SW_FEASIBILITY_ENABLED:-}" == "false" ]]; then
        return 0
    fi
    if type _smart_int >/dev/null 2>&1; then
        local enabled
        enabled=$(_smart_int "feasibility.enabled" 1 2>/dev/null || echo 1)
        [[ "$enabled" == "0" || "$enabled" == "false" ]] && return 0
    fi

    mkdir -p "$artifacts_dir" 2>/dev/null || true

    local intake="$artifacts_dir/intake.json"
    local spec="$artifacts_dir/spec.json"
    local out_json="$artifacts_dir/feasibility.json"
    local out_md="$artifacts_dir/feasibility-report.md"

    local score_payload
    score_payload=$(feasibility_score "$intake" "$spec" 2>/dev/null || echo '{"score":0,"verdict":"BLOCK","checks":[]}')

    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/feas-score.XXXXXX")
    printf '%s\n' "$score_payload" > "$tmp"
    mv "$tmp" "$out_json"

    feasibility_report "$out_json" "$out_md" 2>/dev/null || true

    local score verdict
    score=$(echo "$score_payload" | jq -r '.score' 2>/dev/null || echo 0)
    verdict=$(echo "$score_payload" | jq -r '.verdict' 2>/dev/null || echo "BLOCK")

    if [[ "$(type -t emit_event 2>/dev/null)" == "function" ]]; then
        emit_event "feasibility_check" \
            "issue=${ISSUE_NUMBER:-0}" \
            "score=${score}" \
            "verdict=${verdict}" 2>/dev/null || true
    fi

    if [[ "$verdict" == "BLOCK" ]]; then
        if [[ "$(type -t warn 2>/dev/null)" == "function" ]]; then
            warn "Feasibility BLOCK: score=${score} — see feasibility-report.md"
        else
            echo "Feasibility BLOCK: score=${score}" >&2
        fi
        if [[ "${NO_GITHUB:-}" != "true" && -n "${ISSUE_NUMBER:-}" ]] && command -v gh >/dev/null 2>&1; then
            local body
            body="### Pipeline blocked by feasibility gate"$'\n\n'"Score: **${score}/100** (verdict: \`BLOCK\`)"$'\n\n'"See pipeline artifacts for the full report."
            gh issue comment "$ISSUE_NUMBER" --body "$body" >/dev/null 2>&1 || true
            gh issue edit "$ISSUE_NUMBER" --add-label "pipeline/infeasible" >/dev/null 2>&1 || true
        fi
        return 1
    fi

    if [[ "$(type -t info 2>/dev/null)" == "function" ]]; then
        info "Feasibility ${verdict}: score=${score}/100"
    fi
    return 0
}
