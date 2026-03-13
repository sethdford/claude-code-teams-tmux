# template-recommend.sh — Template success rate tracking & recommendation engine
# Source from sw-template-recommend.sh, sw-daemon.sh, etc.
# Requires: sw-db.sh (for _db_query, _db_exec, db_available)
[[ -n "${_TEMPLATE_RECOMMEND_LOADED:-}" ]] && return 0
_TEMPLATE_RECOMMEND_LOADED=1

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ─── Scoring weights ────────────────────────────────────────────────────────
# Configurable via daemon-config.json: recommendation.weights.*
_TR_WEIGHT_SUCCESS=50
_TR_WEIGHT_SPEED=20
_TR_WEIGHT_COST=20
_TR_WEIGHT_RECENCY=10
_TR_MIN_SAMPLES=3
_TR_CONFIDENCE_FULL=10

# Load weights from config if available
_tr_load_config() {
    local config_file="${REPO_DIR:-.}/.claude/daemon-config.json"
    if [[ -f "$config_file" ]] && command -v jq >/dev/null 2>&1; then
        _TR_WEIGHT_SUCCESS=$(jq -r '.recommendation.weights.success // 50' "$config_file" 2>/dev/null || echo 50)
        _TR_WEIGHT_SPEED=$(jq -r '.recommendation.weights.speed // 20' "$config_file" 2>/dev/null || echo 20)
        _TR_WEIGHT_COST=$(jq -r '.recommendation.weights.cost // 20' "$config_file" 2>/dev/null || echo 20)
        _TR_WEIGHT_RECENCY=$(jq -r '.recommendation.weights.recency // 10' "$config_file" 2>/dev/null || echo 10)
        _TR_MIN_SAMPLES=$(jq -r '.recommendation.min_samples // 3' "$config_file" 2>/dev/null || echo 3)
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Data Collection — record project_type with pipeline outcomes
# ═══════════════════════════════════════════════════════════════════════════

# Detect project type for the current repo
# Returns: nodejs, python, rust, golang, ruby, java, dotnet, c, bash, or unknown
tr_detect_project_type() {
    local root="${1:-.}"

    # Use existing project-detect lib if available
    if [[ -f "$SCRIPT_DIR/lib/project-detect.sh" ]]; then
        # shellcheck source=project-detect.sh
        source "$SCRIPT_DIR/lib/project-detect.sh"
        if type project_detect_type >/dev/null 2>&1; then
            local detection
            detection=$(project_detect_type "$root" 2>/dev/null || echo '{}')
            local ptype
            ptype=$(echo "$detection" | jq -r '.type // "unknown"' 2>/dev/null || echo "unknown")
            if [[ -n "$ptype" && "$ptype" != "null" ]]; then
                echo "$ptype"
                return
            fi
        fi
    fi

    # Fallback: simple marker-file detection
    if [[ -f "$root/package.json" ]]; then echo "nodejs"
    elif [[ -f "$root/pyproject.toml" || -f "$root/setup.py" || -f "$root/requirements.txt" ]]; then echo "python"
    elif [[ -f "$root/Cargo.toml" ]]; then echo "rust"
    elif [[ -f "$root/go.mod" ]]; then echo "golang"
    elif [[ -f "$root/Gemfile" ]]; then echo "ruby"
    elif [[ -f "$root/pom.xml" || -f "$root/build.gradle" ]]; then echo "java"
    elif [[ -f "$root/*.csproj" || -f "$root/*.sln" ]]; then echo "dotnet"
    else echo "unknown"
    fi
}

# Record a pipeline outcome with project_type
# tr_record_outcome <job_id> <template> <success> <duration_secs> <cost_usd> [project_type] [issue] [complexity]
tr_record_outcome() {
    local job_id="$1" template="$2" success="$3" duration="${4:-0}" cost="${5:-0}"
    local project_type="${6:-}" issue="${7:-}" complexity="${8:-medium}"

    # Auto-detect project type if not provided
    if [[ -z "$project_type" ]]; then
        project_type=$(tr_detect_project_type "${REPO_DIR:-.}" 2>/dev/null || echo "unknown")
    fi

    if ! db_available 2>/dev/null; then return 0; fi

    # Use _sql_escape for safety
    job_id=$(_sql_escape "$job_id")
    template=$(_sql_escape "$template")
    project_type=$(_sql_escape "$project_type")
    issue=$(_sql_escape "$issue")
    complexity=$(_sql_escape "$complexity")

    _db_exec "INSERT OR REPLACE INTO pipeline_outcomes
        (job_id, issue_number, template, success, duration_secs, retry_count, cost_usd, complexity, project_type, created_at)
        VALUES ('$job_id', '$issue', '$template', $success, $duration, 0, $cost, '$complexity', '$project_type', '$(date -u +%Y-%m-%dT%H:%M:%SZ)');" 2>/dev/null || true

    # Emit event for observability
    if type emit_event >/dev/null 2>&1; then
        emit_event "template.outcome_recorded" \
            "template=$template" "success=$success" "project_type=$project_type" \
            "duration=$duration" "cost=$cost"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Query Functions — aggregated metrics from pipeline_outcomes
# ═══════════════════════════════════════════════════════════════════════════

# Get success rate for a template, optionally filtered by project_type
# Returns: JSON { "template": "fast", "success_rate": 0.85, "total": 20, "successes": 17, ... }
tr_template_stats() {
    local template="$1"
    local project_type="${2:-}"
    local days="${3:-90}"

    if ! db_available 2>/dev/null; then
        echo '{"error": "db_unavailable"}'
        return 1
    fi

    local where_clause="WHERE template='$(_sql_escape "$template")'"
    where_clause="$where_clause AND created_at >= datetime('now', '-${days} days')"
    if [[ -n "$project_type" ]]; then
        where_clause="$where_clause AND project_type='$(_sql_escape "$project_type")'"
    fi

    _db_query "SELECT json_object(
        'template', '$template',
        'project_type', COALESCE('$project_type', 'all'),
        'total', COUNT(*),
        'successes', SUM(success),
        'success_rate', ROUND(CAST(SUM(success) AS REAL) / MAX(COUNT(*), 1), 3),
        'avg_duration_secs', ROUND(AVG(duration_secs), 0),
        'avg_cost_usd', ROUND(AVG(cost_usd), 4),
        'last_run', MAX(created_at)
    ) FROM pipeline_outcomes $where_clause;" 2>/dev/null || echo '{"error": "query_failed"}'
}

# Get stats for ALL templates, optionally filtered by project_type
# Returns: JSON array
tr_all_template_stats() {
    local project_type="${1:-}"
    local days="${2:-90}"

    if ! db_available 2>/dev/null; then
        echo '[]'
        return 1
    fi

    local where_clause="WHERE created_at >= datetime('now', '-${days} days')"
    if [[ -n "$project_type" ]]; then
        where_clause="$where_clause AND project_type='$(_sql_escape "$project_type")'"
    fi

    _db_query "SELECT '[' || GROUP_CONCAT(j) || ']' FROM (
        SELECT json_object(
            'template', template,
            'project_type', COALESCE(project_type, 'unknown'),
            'total', COUNT(*),
            'successes', SUM(success),
            'success_rate', ROUND(CAST(SUM(success) AS REAL) / MAX(COUNT(*), 1), 3),
            'avg_duration_secs', ROUND(AVG(duration_secs), 0),
            'avg_cost_usd', ROUND(AVG(cost_usd), 4),
            'last_run', MAX(created_at)
        ) as j FROM pipeline_outcomes $where_clause
        GROUP BY template
        ORDER BY COUNT(*) DESC
    );" 2>/dev/null || echo '[]'
}

# ═══════════════════════════════════════════════════════════════════════════
# Recommendation Engine — score and rank templates
# ═══════════════════════════════════════════════════════════════════════════

# Score a template for recommendation
# Returns: JSON { "template": "fast", "score": 82.5, "confidence": "high", ... }
_tr_score_template() {
    local template="$1" project_type="$2" days="${3:-90}"

    local stats
    stats=$(tr_template_stats "$template" "$project_type" "$days" 2>/dev/null)
    local total successes success_rate avg_duration avg_cost last_run
    total=$(echo "$stats" | jq -r '.total // 0' 2>/dev/null || echo 0)
    successes=$(echo "$stats" | jq -r '.successes // 0' 2>/dev/null || echo 0)
    success_rate=$(echo "$stats" | jq -r '.success_rate // 0' 2>/dev/null || echo 0)
    avg_duration=$(echo "$stats" | jq -r '.avg_duration_secs // 0' 2>/dev/null || echo 0)
    avg_cost=$(echo "$stats" | jq -r '.avg_cost_usd // 0' 2>/dev/null || echo 0)
    last_run=$(echo "$stats" | jq -r '.last_run // ""' 2>/dev/null || echo "")

    # Confidence based on sample size
    local confidence="none"
    local confidence_pct=0
    if [[ "$total" -ge "$_TR_CONFIDENCE_FULL" ]]; then
        confidence="high"
        confidence_pct=100
    elif [[ "$total" -ge "$_TR_MIN_SAMPLES" ]]; then
        confidence="medium"
        confidence_pct=$(awk -v t="$total" -v f="$_TR_CONFIDENCE_FULL" 'BEGIN { printf "%.0f", (t / f) * 100 }')
    elif [[ "$total" -gt 0 ]]; then
        confidence="low"
        confidence_pct=$(awk -v t="$total" -v m="$_TR_MIN_SAMPLES" 'BEGIN { printf "%.0f", (t / m) * 50 }')
    fi

    # Success rate score (0-100, weighted at _TR_WEIGHT_SUCCESS%)
    local success_score
    success_score=$(awk -v r="$success_rate" -v w="$_TR_WEIGHT_SUCCESS" 'BEGIN { printf "%.1f", r * w }')

    # Speed score: normalize duration to 0-100 (lower is better)
    # Baseline: 3600s (1hr) = 0, 0s = 100
    local speed_score
    speed_score=$(awk -v d="$avg_duration" -v w="$_TR_WEIGHT_SPEED" 'BEGIN {
        norm = 1 - (d / 3600)
        if (norm < 0) norm = 0
        if (norm > 1) norm = 1
        printf "%.1f", norm * w
    }')

    # Cost score: normalize cost to 0-100 (lower is better)
    # Baseline: $5 = 0, $0 = 100
    local cost_score
    cost_score=$(awk -v c="$avg_cost" -v w="$_TR_WEIGHT_COST" 'BEGIN {
        norm = 1 - (c / 5)
        if (norm < 0) norm = 0
        if (norm > 1) norm = 1
        printf "%.1f", norm * w
    }')

    # Recency score: boost recently used templates
    local recency_score="0"
    if [[ -n "$last_run" && "$last_run" != "null" ]]; then
        # Use days since last run: 0 days = full score, 30+ days = 0
        recency_score=$(awk -v w="$_TR_WEIGHT_RECENCY" 'BEGIN { printf "%.1f", w * 0.5 }')
        # We can't easily calculate date diff in bash 3.2 without GNU date,
        # so use a conservative middle estimate
    fi

    local total_score
    total_score=$(awk -v s="$success_score" -v sp="$speed_score" -v c="$cost_score" -v r="$recency_score" \
        'BEGIN { printf "%.1f", s + sp + c + r }')

    # Scale confidence into score: insufficient data penalizes the score
    if [[ "$total" -lt "$_TR_MIN_SAMPLES" ]]; then
        total_score=$(awk -v s="$total_score" -v p="$confidence_pct" 'BEGIN { printf "%.1f", s * (p / 100) }')
    fi

    echo "{\"template\":\"$template\",\"score\":$total_score,\"confidence\":\"$confidence\",\"confidence_pct\":$confidence_pct,\"total\":$total,\"success_rate\":$success_rate,\"avg_duration_secs\":$avg_duration,\"avg_cost_usd\":$avg_cost}"
}

# Recommend a template based on historical outcomes
# Returns: JSON { "recommended": "fast", "scores": [...], "reason": "...", "confidence": "high" }
tr_recommend() {
    local project_type="${1:-}"
    local days="${2:-90}"

    _tr_load_config

    # Auto-detect project type if not provided
    if [[ -z "$project_type" ]]; then
        project_type=$(tr_detect_project_type "${REPO_DIR:-.}" 2>/dev/null || echo "unknown")
    fi

    if ! db_available 2>/dev/null; then
        # Cold start: no DB → use static project-detect recommendation
        local fallback_rec=""
        if [[ -f "$SCRIPT_DIR/lib/project-detect.sh" ]]; then
            source "$SCRIPT_DIR/lib/project-detect.sh" 2>/dev/null || true
            if type project_recommend_template >/dev/null 2>&1; then
                local rec_json
                rec_json=$(project_recommend_template "${REPO_DIR:-.}" 2>/dev/null || echo '{}')
                fallback_rec=$(echo "$rec_json" | jq -r '.template // "standard"' 2>/dev/null || echo "standard")
            fi
        fi
        fallback_rec="${fallback_rec:-standard}"
        echo "{\"recommended\":\"$fallback_rec\",\"scores\":[],\"reason\":\"cold_start_no_db\",\"confidence\":\"none\",\"project_type\":\"$project_type\"}"
        return 0
    fi

    # Score each known template
    local templates="fast standard full hotfix autonomous enterprise cost-aware deployed"
    local scores_json="["
    local first=1
    local best_template="" best_score=0

    for tpl in $templates; do
        local score_json
        score_json=$(_tr_score_template "$tpl" "$project_type" "$days" 2>/dev/null || echo '{}')

        local tpl_total tpl_score
        tpl_total=$(echo "$score_json" | jq -r '.total // 0' 2>/dev/null || echo 0)
        tpl_score=$(echo "$score_json" | jq -r '.score // 0' 2>/dev/null || echo 0)

        # Only include templates that have been used
        if [[ "$tpl_total" -gt 0 ]]; then
            if [[ "$first" -eq 1 ]]; then
                first=0
            else
                scores_json="${scores_json},"
            fi
            scores_json="${scores_json}${score_json}"

            # Track best
            if awk -v new="$tpl_score" -v best="$best_score" 'BEGIN { exit !(new > best) }' 2>/dev/null; then
                best_score="$tpl_score"
                best_template="$tpl"
            fi
        fi
    done
    scores_json="${scores_json}]"

    # Determine recommendation
    local reason="data_driven" confidence="none"
    if [[ -z "$best_template" ]]; then
        # No data at all: cold start fallback
        best_template="standard"
        reason="cold_start_no_data"
        # Try static recommendation
        if [[ -f "$SCRIPT_DIR/lib/project-detect.sh" ]]; then
            source "$SCRIPT_DIR/lib/project-detect.sh" 2>/dev/null || true
            if type project_recommend_template >/dev/null 2>&1; then
                local rec_json
                rec_json=$(project_recommend_template "${REPO_DIR:-.}" 2>/dev/null || echo '{}')
                best_template=$(echo "$rec_json" | jq -r '.template // "standard"' 2>/dev/null || echo "standard")
                reason="cold_start_project_heuristic"
            fi
        fi
    else
        # Get confidence from the best template's score
        confidence=$(echo "$scores_json" | jq -r --arg t "$best_template" '.[] | select(.template == $t) | .confidence // "none"' 2>/dev/null || echo "none")
    fi

    echo "{\"recommended\":\"$best_template\",\"score\":$best_score,\"scores\":$scores_json,\"reason\":\"$reason\",\"confidence\":\"$confidence\",\"project_type\":\"$project_type\",\"days\":$days}"
}

# ═══════════════════════════════════════════════════════════════════════════
# Dashboard API — formatted data for display
# ═══════════════════════════════════════════════════════════════════════════

# Get success rate trends (7d, 30d, 90d) for dashboard display
tr_success_trends() {
    local project_type="${1:-}"

    if ! db_available 2>/dev/null; then
        echo '{"7d":[],"30d":[],"90d":[]}'
        return 0
    fi

    local trends_7d trends_30d trends_90d
    trends_7d=$(tr_all_template_stats "$project_type" "7" 2>/dev/null || echo '[]')
    trends_30d=$(tr_all_template_stats "$project_type" "30" 2>/dev/null || echo '[]')
    trends_90d=$(tr_all_template_stats "$project_type" "90" 2>/dev/null || echo '[]')

    echo "{\"7d\":$trends_7d,\"30d\":$trends_30d,\"90d\":$trends_90d}"
}
