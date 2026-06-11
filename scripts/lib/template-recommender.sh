#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  template-recommender.sh — Smart Template Recommendation Engine           ║
# ║                                                                           ║
# ║  Pure, deterministic scoring core that recommends the optimal pipeline    ║
# ║  template for an issue from labels, description keywords, complexity,     ║
# ║  repo characteristics, and historical per-template success rates.        ║
# ║                                                                           ║
# ║  Safe to source (no top-level side effects). Bash 3.2 compatible.        ║
# ║  Offline-safe: degrades gracefully with NO_GITHUB / no gh / no network.  ║
# ║                                                                           ║
# ║  Public functions:                                                        ║
# ║    recommend_template <issue_json> [repo_context_json]                    ║
# ║        → JSON {template, confidence, reasoning[], scores{}, signals{}}    ║
# ║    tr_repo_context [repo_dir]  → JSON repo characteristics (or {})        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.3.0"

# Guard against double-sourcing.
if [[ -n "${_TEMPLATE_RECOMMENDER_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_TEMPLATE_RECOMMENDER_LOADED=1

_TR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source compat helpers if available (for _to_lower); provide fallback otherwise.
# shellcheck source=lib/compat.sh
[[ -f "$_TR_DIR/compat.sh" ]] && source "$_TR_DIR/compat.sh" 2>/dev/null || true
[[ "$(type -t _to_lower 2>/dev/null)" == "function" ]] || _to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# emit_event fallback (lib must be safe to source standalone in tests).
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { :; }

# ─── Candidate templates ──────────────────────────────────────────────────────
# The set of templates the engine chooses between. Each must exist as a JSON
# template under templates/pipelines/. Kept narrow to the user-facing set.
TR_CANDIDATES="${TR_CANDIDATES:-fast standard full hotfix enterprise}"

# Feedback log: append-only JSONL of recommendations and outcomes.
TR_FEEDBACK_LOG="${TR_FEEDBACK_LOG:-$HOME/.shipwright/optimization/template-recommendations.jsonl}"

# ─── Scoring accumulators (flat vars — bash 3.2, no associative arrays) ────────
_tr_reset_scores() {
    _tr_s_fast=10
    _tr_s_standard=30
    _tr_s_full=10
    _tr_s_hotfix=0
    _tr_s_enterprise=0
    _tr_reasoning=""   # newline-separated human strings
}

# _tr_add <template> <points> <reason>
# Adds points to a template's score and records a reasoning line.
_tr_add() {
    local tmpl="$1" pts="$2" reason="$3"
    case "$tmpl" in
        fast)       _tr_s_fast=$((_tr_s_fast + pts)) ;;
        standard)   _tr_s_standard=$((_tr_s_standard + pts)) ;;
        full)       _tr_s_full=$((_tr_s_full + pts)) ;;
        hotfix)     _tr_s_hotfix=$((_tr_s_hotfix + pts)) ;;
        enterprise) _tr_s_enterprise=$((_tr_s_enterprise + pts)) ;;
        *) return 0 ;;
    esac
    if [[ -n "$reason" ]]; then
        local sign="+"
        [[ "$pts" -lt 0 ]] && sign=""
        if [[ -z "$_tr_reasoning" ]]; then
            _tr_reasoning="${reason} (${sign}${pts} ${tmpl})"
        else
            _tr_reasoning="${_tr_reasoning}
${reason} (${sign}${pts} ${tmpl})"
        fi
    fi
}

# ─── Repo context (offline-safe) ──────────────────────────────────────────────
# Returns JSON: {file_count, test_count, test_ratio, language}. Falls back to {}
# when not in a git repo / git unavailable. Never makes network calls.
# shellcheck disable=SC2120  # repo_dir is optional; callers may pass it
tr_repo_context() {
    local repo_dir="${1:-${REPO_DIR:-$PWD}}"
    (
        cd "$repo_dir" 2>/dev/null || { echo "{}"; exit 0; }
        command -v git >/dev/null 2>&1 || { echo "{}"; exit 0; }
        git rev-parse --git-dir >/dev/null 2>&1 || { echo "{}"; exit 0; }

        local files file_count test_count language=""
        files=$(git ls-files 2>/dev/null || true)
        file_count=$(printf '%s\n' "$files" | grep -c . 2>/dev/null || true)
        file_count="${file_count:-0}"
        test_count=$(printf '%s\n' "$files" | grep -ciE '(^|/)(test|tests|spec|specs|__tests__)/|[._-](test|spec)\.' 2>/dev/null || true)
        test_count="${test_count:-0}"

        # Language: detect via project markers (best-effort, no network).
        if [[ -f package.json ]]; then language="javascript"
        elif [[ -f go.mod ]]; then language="go"
        elif [[ -f Cargo.toml ]]; then language="rust"
        elif [[ -f pyproject.toml || -f setup.py || -f requirements.txt ]]; then language="python"
        elif [[ -f pom.xml || -f build.gradle ]]; then language="java"
        fi

        local ratio="0"
        if [[ "$file_count" -gt 0 ]]; then
            ratio=$(awk -v t="$test_count" -v f="$file_count" 'BEGIN { printf "%.3f", t / f }')
        fi

        jq -n \
            --argjson fc "$file_count" \
            --argjson tc "$test_count" \
            --arg ratio "$ratio" \
            --arg lang "$language" \
            '{file_count: $fc, test_count: $tc, test_ratio: ($ratio|tonumber), language: $lang}'
    )
}

# ─── Issue-type classification (mirrors daemon-triage precedence) ─────────────
# Echoes one of: hotfix, bug, security, docs, feature.
_tr_issue_type() {
    local labels_lc="$1" text_lc="$2"
    case "$labels_lc $text_lc" in
        *hotfix*|*incident*|*p0*|*outage*) echo "hotfix"; return ;;
    esac
    case "$labels_lc" in
        *security*|*vulnerability*|*cve*) echo "security"; return ;;
        *bug*) echo "bug"; return ;;
        *doc*|*chore*) echo "docs"; return ;;
    esac
    case "$text_lc" in
        *security*|*vulnerab*) echo "security"; return ;;
    esac
    echo "feature"
}

# ─── Historical success bonus ─────────────────────────────────────────────────
# Awards a small bonus to the historically-best template for this issue type,
# using the bandit selector posterior if loaded. Offline/clean state → no-op.
_tr_history_bonus() {
    local issue_type="$1"
    if [[ "$(type -t bandit_select_template 2>/dev/null)" == "function" ]]; then
        local best
        best=$(_tr_bandit_pick "$issue_type")
        if [[ -n "$best" ]]; then
            _tr_add "$best" 12 "historical success for '${issue_type}' favors '${best}'"
        fi
    fi
}

_tr_bandit_pick() {
    local issue_type="$1"
    local csv
    csv=$(echo "$TR_CANDIDATES" | tr ' ' ',')
    bandit_select_template "$issue_type" "$csv" 2>/dev/null | tail -1 || true
}

# ─── Core scoring ─────────────────────────────────────────────────────────────
# _tr_score_templates <issue_json> <repo_context_json>
# Populates _tr_s_* accumulators, _tr_reasoning, and _tr_issue_type_result.
# Must be called directly (NOT in a command-substitution subshell) so the
# accumulator variables persist to the caller.
_tr_score_templates() {
    local issue_json="$1" repo_json="${2:-{\}}"

    local title body labels_csv
    title=$(echo "$issue_json" | jq -r '.title // ""' 2>/dev/null || echo "")
    body=$(echo "$issue_json" | jq -r '.body // ""' 2>/dev/null || echo "")
    labels_csv=$(echo "$issue_json" | jq -r '(.labels // []) | map(if type=="object" then .name else . end) | join(",")' 2>/dev/null || echo "")

    local text_lc labels_lc
    text_lc=$(_to_lower "$title $body")
    labels_lc=$(_to_lower "$labels_csv")

    _tr_reset_scores

    # ── Labels (highest precedence) ──
    case "$labels_lc" in
        *hotfix*|*incident*|*p0*|*urgent*) _tr_add hotfix 50 "label signals urgency" ;;
    esac
    case "$labels_lc" in
        *security*|*vulnerability*|*cve*) _tr_add enterprise 45 "security label → maximum-safety template" ;;
    esac
    case "$labels_lc" in
        *bug*) _tr_add standard 20 "bug label → standard pipeline" ;;
    esac
    case "$labels_lc" in
        *doc*|*chore*|*typo*) _tr_add fast 35 "docs/chore label → fast pipeline" ;;
    esac
    case "$labels_lc" in
        *feature*|*enhancement*) _tr_add standard 15 "feature label → standard"; _tr_add full 10 "feature label → full eligible" ;;
    esac

    # ── Description keywords ──
    case "$text_lc" in
        *refactor*|*migration*|*migrate*|*breaking*|*architecture*|*redesign*) _tr_add full 25 "keyword (refactor/migration/architecture) → full" ;;
    esac
    case "$text_lc" in
        *typo*|*readme*|*comment*|*formatting*|*"version bump"*) _tr_add fast 25 "trivial-change keyword → fast" ;;
    esac
    case "$text_lc" in
        *auth*|*payment*|*crypto*|*secret*|*password*|*token*|*credential*) _tr_add enterprise 30 "sensitive keyword (auth/payment/crypto) → enterprise" ;;
    esac
    case "$text_lc" in
        *"production down"*|*outage*|*asap*|*"urgent fix"*) _tr_add hotfix 30 "incident keyword → hotfix" ;;
    esac

    # ── Complexity heuristic (length + signal keywords) ──
    local body_len complexity
    body_len=${#body}
    complexity=$(_tr_complexity "$text_lc" "$body_len")
    if [[ "$complexity" -lt 40 ]]; then
        _tr_add fast 15 "low complexity (${complexity}) → fast eligible"
    elif [[ "$complexity" -le 70 ]]; then
        _tr_add standard 15 "medium complexity (${complexity}) → standard"
    else
        _tr_add full 15 "high complexity (${complexity}) → full"
    fi

    # ── Repo size ──
    local file_count test_ratio
    file_count=$(echo "$repo_json" | jq -r '.file_count // 0' 2>/dev/null || echo 0)
    test_ratio=$(echo "$repo_json" | jq -r '.test_ratio // 0' 2>/dev/null || echo 0)
    if [[ "$file_count" -gt 0 && "$file_count" -lt 100 ]]; then
        _tr_add fast 10 "small repo (${file_count} files) → fast eligible"
    elif [[ "$file_count" -gt 1000 ]]; then
        _tr_add full 10 "large repo (${file_count} files) → full"
    fi

    # ── Test coverage ──
    local low_cov
    low_cov=$(awk -v r="$test_ratio" 'BEGIN { print (r > 0 && r < 0.1) ? "1" : "0" }')
    if [[ "$low_cov" == "1" ]]; then
        _tr_add enterprise 10 "low test coverage (ratio ${test_ratio}) → extra gates"
        _tr_add full 8 "low test coverage → full review"
    fi

    # ── Historical success ──
    local issue_type
    issue_type=$(_tr_issue_type "$labels_lc" "$text_lc")
    _tr_history_bonus "$issue_type"

    _tr_issue_type_result="$issue_type"
}

# Complexity heuristic 0-100 from text + body length.
_tr_complexity() {
    local text_lc="$1" body_len="$2"
    local score=20
    [[ "$body_len" -gt 200 ]] && score=$((score + 10))
    [[ "$body_len" -gt 800 ]] && score=$((score + 15))
    [[ "$body_len" -gt 2000 ]] && score=$((score + 15))
    case "$text_lc" in *refactor*|*architecture*|*migration*|*redesign*|*"distributed"*) score=$((score + 25)) ;; esac
    case "$text_lc" in *multiple*|*several*|*complex*|*"end-to-end"*|*"end to end"*) score=$((score + 15)) ;; esac
    case "$text_lc" in *typo*|*readme*|*comment*|*rename*) score=$((score - 15)) ;; esac
    [[ "$score" -lt 0 ]] && score=0
    [[ "$score" -gt 100 ]] && score=100
    echo "$score"
}

# ─── Public: recommend_template ───────────────────────────────────────────────
# Usage: recommend_template <issue_json> [repo_context_json]
# Output (stdout): canonical JSON object.
recommend_template() {
    local issue_json="${1:-{\}}"
    local repo_json="${2:-}"
    [[ -z "$repo_json" ]] && repo_json=$(tr_repo_context)

    local issue_type
    _tr_issue_type_result=""
    _tr_score_templates "$issue_json" "$repo_json"
    issue_type="$_tr_issue_type_result"

    # Argmax across candidates.
    local top_tmpl="standard" top_score=-1 second_score=0
    local tmpl sc
    for tmpl in $TR_CANDIDATES; do
        case "$tmpl" in
            fast) sc=$_tr_s_fast ;;
            standard) sc=$_tr_s_standard ;;
            full) sc=$_tr_s_full ;;
            hotfix) sc=$_tr_s_hotfix ;;
            enterprise) sc=$_tr_s_enterprise ;;
            *) sc=0 ;;
        esac
        if [[ "$sc" -gt "$top_score" ]]; then
            second_score=$top_score
            top_score=$sc
            top_tmpl=$tmpl
        elif [[ "$sc" -gt "$second_score" ]]; then
            second_score=$sc
        fi
    done
    [[ "$second_score" -lt 0 ]] && second_score=0

    # Separation-based confidence: how far ahead is the winner?
    local confidence
    if [[ "$top_score" -le 0 ]]; then
        confidence=0
    else
        confidence=$(awk -v t="$top_score" -v s="$second_score" \
            'BEGIN { c = 100 * t / (t + s); if (c > 100) c = 100; if (c < 0) c = 0; printf "%d", c + 0.5 }')
    fi

    # Build scores + reasoning JSON.
    local scores_json reasoning_json
    scores_json=$(jq -n \
        --argjson fast "$_tr_s_fast" \
        --argjson standard "$_tr_s_standard" \
        --argjson full "$_tr_s_full" \
        --argjson hotfix "$_tr_s_hotfix" \
        --argjson enterprise "$_tr_s_enterprise" \
        '{fast: $fast, standard: $standard, full: $full, hotfix: $hotfix, enterprise: $enterprise}')

    if [[ -n "$_tr_reasoning" ]]; then
        reasoning_json=$(printf '%s\n' "$_tr_reasoning" | jq -R . | jq -s .)
    else
        reasoning_json='["default heuristics applied"]'
    fi

    jq -n \
        --arg template "$top_tmpl" \
        --argjson confidence "$confidence" \
        --argjson reasoning "$reasoning_json" \
        --argjson scores "$scores_json" \
        --arg issue_type "$issue_type" \
        '{template: $template, confidence: $confidence, reasoning: $reasoning, scores: $scores, signals: {issue_type: $issue_type}}'

    emit_event "template.recommendation" "template=$top_tmpl" "confidence=$confidence" "issue_type=$issue_type" 2>/dev/null || true
}

# ─── Feedback loop ────────────────────────────────────────────────────────────
# tr_record_recommendation <issue> <template> <confidence> <applied>
tr_record_recommendation() {
    local issue="${1:-0}" template="${2:-}" confidence="${3:-0}" applied="${4:-false}" ts="${5:-}"
    [[ -z "$ts" ]] && ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    mkdir -p "$(dirname "$TR_FEEDBACK_LOG")" 2>/dev/null || true
    jq -nc \
        --arg ts "$ts" \
        --arg issue "$issue" \
        --arg template "$template" \
        --argjson confidence "${confidence:-0}" \
        --arg applied "$applied" \
        '{ts: $ts, issue: $issue, recommended: $template, confidence: $confidence, applied: ($applied=="true"), actual: null, outcome: null}' \
        >> "$TR_FEEDBACK_LOG" 2>/dev/null || true
}

# tr_record_outcome <issue> <actual_template> <outcome>
# Appends an outcome record and updates bandit arms if available.
tr_record_outcome() {
    local issue="${1:-0}" actual="${2:-}" outcome="${3:-failure}" ts="${4:-}"
    [[ -z "$ts" ]] && ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    mkdir -p "$(dirname "$TR_FEEDBACK_LOG")" 2>/dev/null || true
    jq -nc \
        --arg ts "$ts" \
        --arg issue "$issue" \
        --arg actual "$actual" \
        --arg outcome "$outcome" \
        '{ts: $ts, issue: $issue, recommended: null, confidence: null, applied: null, actual: $actual, outcome: $outcome}' \
        >> "$TR_FEEDBACK_LOG" 2>/dev/null || true

    if [[ "$(type -t bandit_update 2>/dev/null)" == "function" && -n "$actual" ]]; then
        bandit_update template "${5:-feature}:${actual}" "$outcome" >/dev/null 2>&1 || true
    fi
}

# tr_accuracy → JSON {total, matched, accuracy} comparing recommended vs actual
# template per issue in the feedback log.
tr_accuracy() {
    if [[ ! -f "$TR_FEEDBACK_LOG" ]]; then
        echo '{"total": 0, "matched": 0, "accuracy": 0}'
        return 0
    fi
    jq -s '
        # group records by issue, find recommended + actual for each
        (group_by(.issue)
          | map({
              issue: .[0].issue,
              recommended: (map(.recommended) | map(select(. != null)) | last),
              actual: (map(.actual) | map(select(. != null)) | last)
            })
          | map(select(.recommended != null and .actual != null))) as $pairs
        | ($pairs | length) as $total
        | ($pairs | map(select(.recommended == .actual)) | length) as $matched
        | {total: $total, matched: $matched,
           accuracy: (if $total > 0 then (100 * $matched / $total | floor) else 0 end)}
    ' "$TR_FEEDBACK_LOG" 2>/dev/null || echo '{"total": 0, "matched": 0, "accuracy": 0}'
}
