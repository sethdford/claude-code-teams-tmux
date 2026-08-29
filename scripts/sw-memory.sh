#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright memory — Persistent Learning & Context System                     ║
# ║  Captures learnings · Injects context · Searches memory · Tracks metrics║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload
    payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
# ─── Database (for dual-write memory to DB) ───────────────────────────────────
# shellcheck source=sw-db.sh
[[ -f "$SCRIPT_DIR/sw-db.sh" ]] && source "$SCRIPT_DIR/sw-db.sh"

# ─── Intelligence Engine (optional) ──────────────────────────────────────────
# shellcheck source=sw-intelligence.sh
[[ -f "$SCRIPT_DIR/sw-intelligence.sh" ]] && source "$SCRIPT_DIR/sw-intelligence.sh"

# ─── Memory Effectiveness Tracker ──────────────────────────────────────────
# shellcheck source=lib/memory-effectiveness.sh
[[ -f "$SCRIPT_DIR/lib/memory-effectiveness.sh" ]] && source "$SCRIPT_DIR/lib/memory-effectiveness.sh"

# ─── Pattern capture & cross-pipeline discovery ────────────────────────────
# shellcheck source=lib/memory-discovery.sh
[[ -f "$SCRIPT_DIR/lib/memory-discovery.sh" ]] && source "$SCRIPT_DIR/lib/memory-discovery.sh"

# ─── Cost tracking & DORA metrics ──────────────────────────────────────────
# shellcheck source=lib/memory-cost.sh
[[ -f "$SCRIPT_DIR/lib/memory-cost.sh" ]] && source "$SCRIPT_DIR/lib/memory-cost.sh"

# ─── Memory Storage Paths ──────────────────────────────────────────────────
MEMORY_ROOT="${HOME}/.shipwright/memory"
GLOBAL_MEMORY="${MEMORY_ROOT}/global.json"

# ─── Domain keyword expansion (shared semantic concept) ──────────────────────

_expand_domain_keywords() {
    local text="$1"
    local expanded="$text"

    local dom
    for dom in auth api db ui test deploy error perf; do
        case "$dom" in
            auth)   [[ "$text" =~ [aA]uth ]] && expanded="$expanded authentication authorization login session token credential permission access" ;;
            api)    [[ "$text" =~ [aA]pi ]]  && expanded="$expanded endpoint route handler request response rest graphql" ;;
            db)     [[ "$text" =~ [dD]b ]]   && expanded="$expanded database query migration schema model table sql" ;;
            ui)     [[ "$text" =~ [uU]i ]]   && expanded="$expanded component view render template layout style css frontend" ;;
            test)   [[ "$text" =~ [tT]est ]] && expanded="$expanded testing assertion coverage mock stub fixture spec" ;;
            deploy) [[ "$text" =~ [dD]eploy ]] && expanded="$expanded deployment release publish ship ci cd pipeline" ;;
            error)  [[ "$text" =~ [eE]rror ]] && expanded="$expanded exception failure crash bug issue defect" ;;
            perf)   [[ "$text" =~ [pP]erf ]] && expanded="$expanded performance optimization speed latency throughput cache" ;;
        esac
    done

    echo "$expanded"
}

# ─── Embedding & Semantic Search ───────────────────────────────────────────

# Generate content hash for deduplication
_memory_content_hash() {
    echo -n "$1" | shasum -a 256 | cut -d' ' -f1
}

# TF-IDF-like ranked search across failures, patterns, decisions
# Returns JSON array of {source_type, content_text} for injection compatibility
memory_ranked_search() {
    local query="$1"
    local memory_dir="$2"
    local max_results="${3:-5}"

    # Use repo memory dir when not specified
    if [[ -z "$memory_dir" ]] && type repo_memory_dir &>/dev/null 2>&1; then
        memory_dir="$(repo_memory_dir)"
    fi
    memory_dir="${memory_dir:-$HOME/.shipwright/memory}"
    if [[ ! -d "$memory_dir" ]]; then
        info "Memory dir not found at ${memory_dir} — auto-creating"
        mkdir -p "$memory_dir"
        emit_event "memory.not_available" "path=$memory_dir" "action=auto_created"
        echo "[]"
        return 0
    fi

    # Extract and expand query keywords
    local keywords
    keywords=$(echo "$query" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u | \
        grep -vxE '^.{1,2}$|^(the|and|for|not|with|this|that|from)$' || true)
    keywords=$(_expand_domain_keywords "$keywords" 2>/dev/null || echo "$keywords")

    local results_file
    results_file=$(mktemp)

    # Search failures.json
    if [[ -f "$memory_dir/failures.json" ]]; then
        jq -c '.failures[]? // empty' "$memory_dir/failures.json" 2>/dev/null | while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            local entry_text
            entry_text=$(echo "$entry" | jq -r '(.pattern // "") + " " + (.root_cause // "") + " " + (.fix // "")' 2>/dev/null)
            local score=0
            while IFS= read -r kw; do
                [[ -z "$kw" ]] && continue
                if echo "$entry_text" | grep -qiF "$kw" 2>/dev/null; then
                    score=$((score + 1))
                fi
            done <<< "$keywords"

            # Boost by effectiveness
            local effectiveness
            effectiveness=$(echo "$entry" | jq -r '.fix_effectiveness_rate // 0' 2>/dev/null)
            if [[ "$effectiveness" =~ ^[0-9]+$ ]] && [[ "$effectiveness" -gt 50 ]]; then
                score=$((score + 2))
            fi

            if [[ "$score" -gt 0 ]]; then
                local content
                content=$(echo "$entry" | jq -r '(.pattern // "") + " | " + (.root_cause // "") + " | " + (.fix // "")' 2>/dev/null)
                echo "${score}|{\"source_type\":\"failure\",\"content_text\":$(echo "$content" | jq -Rs .)}" >> "$results_file"
            fi
        done
    fi

    # Search decisions.json
    if [[ -f "$memory_dir/decisions.json" ]]; then
        jq -c '.decisions[]? // empty' "$memory_dir/decisions.json" 2>/dev/null | while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            local entry_text
            entry_text=$(echo "$entry" | jq -r '(.summary // "") + " " + (.detail // "") + " " + (.type // "")' 2>/dev/null)
            local score=0
            while IFS= read -r kw; do
                [[ -z "$kw" ]] && continue
                echo "$entry_text" | grep -qiF "$kw" 2>/dev/null && score=$((score + 1))
            done <<< "$keywords"
            if [[ "$score" -gt 0 ]]; then
                local content
                content=$(echo "$entry" | jq -r '(.summary // "") + " | " + (.detail // "")' 2>/dev/null)
                echo "${score}|{\"source_type\":\"decision\",\"content_text\":$(echo "$content" | jq -Rs .)}" >> "$results_file"
            fi
        done
    fi

    # Search patterns.json (project, conventions, known_issues as text)
    if [[ -f "$memory_dir/patterns.json" ]]; then
        local entry_text
        entry_text=$(jq -r 'to_entries | map(select(.key != "known_issues")) | from_entries | tostring' "$memory_dir/patterns.json" 2>/dev/null || echo "")
        entry_text="$entry_text $(jq -r '.known_issues[]? // empty' "$memory_dir/patterns.json" 2>/dev/null | tr '\n' ' ')"
        local score=0
        while IFS= read -r kw; do
            [[ -z "$kw" ]] && continue
            echo "$entry_text" | grep -qiF "$kw" 2>/dev/null && score=$((score + 1))
        done <<< "$keywords"
        if [[ "$score" -gt 0 ]]; then
            local content
            content=$(jq -r 'to_entries | map("\(.key): \(.value)") | join(" | ")' "$memory_dir/patterns.json" 2>/dev/null | head -c 500)
            echo "${score}|{\"source_type\":\"pattern\",\"content_text\":$(echo "$content" | jq -Rs .)}" >> "$results_file"
        fi
    fi

    # Sort by score and output as JSON array
    local output
    if [[ -s "$results_file" ]]; then
        output=$(sort -t'|' -k1 -rn "$results_file" | head -"$max_results" | cut -d'|' -f2- | jq -s '.' 2>/dev/null || echo "[]")
    else
        output="[]"
    fi
    rm -f "$results_file" 2>/dev/null || true
    echo "$output"
}

# Store a memory with its text content for future embedding
memory_store_for_embedding() {
    local source_type="$1" content_text="$2" repo_hash="${3:-}"
    local content_hash
    content_hash=$(_memory_content_hash "$content_text")

    if type db_save_embedding >/dev/null 2>&1; then
        db_save_embedding "$content_hash" "$source_type" "$content_text" "$repo_hash" 2>/dev/null || true
    fi
}

# Check if vector embeddings search is available (future: SQLite vec0, etc.)
_has_embeddings() {
    return 1  # No embedding-based search yet
}

# Semantic search: embeddings when available, else TF-IDF-like ranked keyword search
memory_semantic_search() {
    local query="$1" repo_hash="${2:-}" limit="${3:-5}"

    if _has_embeddings 2>/dev/null; then
        # Future: _search_embeddings "$query" "$repo_hash" "$limit"
        :
    fi

    # Fall back to ranked keyword search (better than SQL LIKE or grep)
    local mem_dir
    mem_dir=""
    if type repo_memory_dir &>/dev/null 2>&1; then
        mem_dir="$(repo_memory_dir)"
    fi
    memory_ranked_search "$query" "$mem_dir" "$limit"
}

# Inject relevant memories into agent prompts (goal-based)
memory_inject_goal_context() {
    # shellcheck disable=SC2034
    local goal="$1" repo_hash="${2:-}" max_tokens="${3:-2000}"

    local memories
    memories=$(memory_semantic_search "$goal" "$repo_hash" 5 2>/dev/null || echo "[]")

    if [[ "$memories" == "[]" || -z "$memories" ]]; then
        return
    fi

    echo "## Relevant Past Context"
    echo ""
    echo "$memories" | jq -r '.[] | "- [\(.source_type)] \(.content_text | .[0:200])"' 2>/dev/null || true
    echo ""
}

# Get a deterministic hash for the current repo
repo_hash() {
    local origin
    origin=$(git config --get remote.origin.url 2>/dev/null || echo "local")
    echo -n "$origin" | shasum -a 256 | cut -c1-12
}

repo_name() {
    git config --get remote.origin.url 2>/dev/null \
        | sed 's|.*[:/]\([^/]*/[^/]*\)\.git$|\1|' \
        | sed 's|.*[:/]\([^/]*/[^/]*\)$|\1|' \
        || echo "local"
}

repo_memory_dir() {
    echo "${MEMORY_ROOT}/$(repo_hash)"
}

ensure_memory_dir() {
    local dir
    dir="$(repo_memory_dir)"
    mkdir -p "$dir"

    # Initialize empty JSON files if they don't exist
    [[ -f "$dir/patterns.json" ]]  || echo '{}' > "$dir/patterns.json"
    [[ -f "$dir/failures.json" ]]  || echo '{"failures":[]}' > "$dir/failures.json"
    [[ -f "$dir/decisions.json" ]] || echo '{"decisions":[]}' > "$dir/decisions.json"
    [[ -f "$dir/metrics.json" ]]   || echo '{"baselines":{}}' > "$dir/metrics.json"

    # Initialize global memory if missing
    mkdir -p "$MEMORY_ROOT"
    [[ -f "$GLOBAL_MEMORY" ]] || echo '{"common_patterns":[],"cross_repo_learnings":[]}' > "$GLOBAL_MEMORY"
}


# memory_inject_context <stage_id>
# Returns a text block of relevant memory for a given pipeline stage.
# When intelligence engine is available, uses AI-ranked search for better relevance.
memory_inject_context() {
    local stage_id="${1:-}"

    # Try intelligence-ranked search first
    if type intelligence_search_memory >/dev/null 2>&1; then
        local config="${REPO_DIR:-.}/.claude/daemon-config.json"
        local intel_enabled="false"
        if [[ -f "$config" ]]; then
            intel_enabled=$(jq -r '.intelligence.enabled // false' "$config" 2>/dev/null || echo "false")
        fi
        if [[ "$intel_enabled" == "true" ]]; then
            local ranked_result
            ranked_result=$(intelligence_search_memory "$stage_id stage context" "$(repo_memory_dir)" 5 2>/dev/null || echo "")
            if [[ -n "$ranked_result" ]] && [[ "$ranked_result" != *'"error"'* ]]; then
                echo "$ranked_result"
                return 0
            fi
        fi
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"

    # Check that we have memory to inject
    local has_memory=false
    for f in "$mem_dir/patterns.json" "$mem_dir/failures.json" "$mem_dir/decisions.json"; do
        if [[ -f "$f" ]] && [[ "$(wc -c < "$f")" -gt 5 ]]; then
            has_memory=true
            break
        fi
    done

    if [[ "$has_memory" == "false" ]]; then
        info "No memory available for repo (${mem_dir}) — first pipeline run will seed it"
        echo "# No memory available for this repository yet."
        return 0
    fi

    echo "# Shipwright Memory Context"
    echo "# Injected at: $(now_iso)"
    echo "# Stage: ${stage_id}"
    echo ""

    case "$stage_id" in
        plan|design)
            # Past design decisions + codebase patterns
            echo "## Codebase Patterns"
            if [[ -f "$mem_dir/patterns.json" ]]; then
                local proj_type framework lang
                proj_type=$(jq -r '.project.type // "unknown"' "$mem_dir/patterns.json" 2>/dev/null)
                framework=$(jq -r '.project.framework // ""' "$mem_dir/patterns.json" 2>/dev/null)
                lang=$(jq -r '.project.language // ""' "$mem_dir/patterns.json" 2>/dev/null)
                echo "- Project: ${proj_type} / ${framework:-no framework} / ${lang:-unknown}"

                local src_dir test_pat
                src_dir=$(jq -r '.conventions.source_dir // ""' "$mem_dir/patterns.json" 2>/dev/null)
                test_pat=$(jq -r '.conventions.test_pattern // ""' "$mem_dir/patterns.json" 2>/dev/null)
                [[ -n "$src_dir" ]] && echo "- Source directory: ${src_dir}"
                [[ -n "$test_pat" ]] && echo "- Test file pattern: ${test_pat}"
            fi

            echo ""
            echo "## Past Design Decisions"
            if [[ -f "$mem_dir/decisions.json" ]]; then
                jq -r '.decisions[-5:][] | "- [\(.type // "decision")] \(.summary // .description // "no description")"' \
                    "$mem_dir/decisions.json" 2>/dev/null || echo "- No decisions recorded yet."
            fi

            echo ""
            echo "## Known Issues"
            if [[ -f "$mem_dir/patterns.json" ]]; then
                jq -r '.known_issues // [] | .[] | "- \(.)"' "$mem_dir/patterns.json" 2>/dev/null || true
            fi
            ;;

        build)
            # Failure patterns to avoid — ranked by relevance (recency + effectiveness + frequency)
            echo "## Failure Patterns to Avoid"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r 'now as $now |
                    .failures | map(. +
                        { relevance_score:
                            ((.seen_count // 1) * 1) +
                            (if .fix_effectiveness_rate then (.fix_effectiveness_rate / 10) else 0 end) +
                            (if .last_seen then
                                (($now - ((.last_seen | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) // 0)) |
                                 if . < 86400 then 5
                                 elif . < 604800 then 3
                                 elif . < 2592000 then 1
                                 else 0 end)
                            else 0 end)
                        }
                    ) | sort_by(-.relevance_score) | .[:10][] |
                    "- [\(.stage)] \(.pattern) (seen \(.seen_count)x)" +
                    if .fix != "" then
                        "\n  Fix: \(.fix)" +
                        if .fix_effectiveness_rate then " (effectiveness: \(.fix_effectiveness_rate)%)" else "" end
                    else "" end' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No failures recorded."
            fi

            echo ""
            echo "## Known Fixes"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r '.failures[] | select(.root_cause != "" and .fix != "" and .stage == "build") |
                    "- [\(.category // "unknown")] \(.root_cause)\n  Fix: \(.fix)" +
                    if .fix_effectiveness_rate then " (effectiveness: \(.fix_effectiveness_rate)%)" else "" end' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No analyzed fixes yet."
            else
                echo "- No analyzed fixes yet."
            fi

            echo ""
            echo "## Code Conventions"
            if [[ -f "$mem_dir/patterns.json" ]]; then
                local import_style
                import_style=$(jq -r '.conventions.import_style // ""' "$mem_dir/patterns.json" 2>/dev/null)
                [[ -n "$import_style" ]] && echo "- Import style: ${import_style}"
                local test_runner
                test_runner=$(jq -r '.project.test_runner // ""' "$mem_dir/patterns.json" 2>/dev/null)
                [[ -n "$test_runner" ]] && echo "- Test runner: ${test_runner}"
            fi
            ;;

        test)
            # Known flaky tests + coverage baselines
            echo "## Known Test Failures"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r '.failures[] | select(.stage == "test") |
                    "- \(.pattern) (seen \(.seen_count)x)" +
                    if .fix != "" then "\n  Fix: \(.fix)" else "" end' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No test failures recorded."
            fi

            echo ""
            echo "## Known Fixes"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r '.failures[] | select(.root_cause != "" and .fix != "" and .stage == "test") |
                    "- [\(.category // "unknown")] \(.root_cause)\n  Fix: \(.fix)"' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No analyzed fixes yet."
            else
                echo "- No analyzed fixes yet."
            fi

            echo ""
            echo "## Performance Baselines"
            if [[ -f "$mem_dir/metrics.json" ]]; then
                local test_dur coverage
                test_dur=$(jq -r '.baselines.test_duration_s // "not tracked"' "$mem_dir/metrics.json" 2>/dev/null)
                coverage=$(jq -r '.baselines.coverage_pct // "not tracked"' "$mem_dir/metrics.json" 2>/dev/null)
                echo "- Test duration baseline: ${test_dur}s"
                echo "- Coverage baseline: ${coverage}%"
            fi
            ;;

        review|compound_quality)
            # Past review feedback patterns
            echo "## Common Review Feedback"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r '.failures[] | select(.stage == "review") |
                    "- \(.pattern)"' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- No review patterns recorded."
            fi

            echo ""
            echo "## Cross-Repo Learnings"
            if [[ -f "$GLOBAL_MEMORY" ]]; then
                jq -r '.cross_repo_learnings[-5:][] |
                    "- [\(.repo)] \(.type): \(.bugs // 0) bugs, \(.warnings // 0) warnings"' \
                    "$GLOBAL_MEMORY" 2>/dev/null || true
            fi
            ;;

        *)
            # Generic context — use ranked semantic search when intelligence unavailable
            if ! type intelligence_search_memory &>/dev/null 2>&1; then
                local ranked_json
                ranked_json=$(memory_ranked_search "${stage_id} stage context" "$mem_dir" 5 2>/dev/null || echo "[]")
                if [[ -n "$ranked_json" && "$ranked_json" != "[]" ]]; then
                    echo "## Ranked Relevant Memory"
                    echo "$ranked_json" | jq -r '.[]? | "- [\(.source_type)] \(.content_text[0:200])"' 2>/dev/null || true
                    echo ""
                fi
            fi

            echo "## Repository Patterns"
            if [[ -f "$mem_dir/patterns.json" ]]; then
                jq -r 'to_entries | map(select(.key != "known_issues")) | from_entries' \
                    "$mem_dir/patterns.json" 2>/dev/null || true
            fi

            # Inject top failures regardless of category (ranked by relevance)
            echo ""
            echo "## Relevant Failure Patterns"
            if [[ -f "$mem_dir/failures.json" ]]; then
                jq -r --arg stg "$stage_id" \
                    '.failures |
                     map(. + { stage_match: (if .stage == $stg then 10 else 0 end) }) |
                     sort_by(-(.seen_count + .stage_match + (.fix_effectiveness_rate // 0) / 10)) |
                     .[:5][] |
                     "- [\(.stage)] \(.pattern[:80]) (seen \(.seen_count)x)" +
                     if .fix != "" then "\n  Fix: \(.fix)" else "" end' \
                    "$mem_dir/failures.json" 2>/dev/null || echo "- None recorded."
            fi

            # Inject recent decisions
            echo ""
            echo "## Recent Decisions"
            if [[ -f "$mem_dir/decisions.json" ]]; then
                jq -r '.decisions[-3:][] |
                    "- [\(.type // "decision")] \(.summary // "no description")"' \
                    "$mem_dir/decisions.json" 2>/dev/null || echo "- None recorded."
            fi
            ;;
    esac

    # ── Cross-repo memory injection (global learnings) ──
    if [[ -f "$GLOBAL_MEMORY" ]]; then
        local global_patterns
        global_patterns=$(jq -r --arg stage "$stage_id" '
            .common_patterns // [] | .[] |
            select(.category == $stage or .category == "general" or .category == null) |
            .summary // .description // empty
        ' "$GLOBAL_MEMORY" 2>/dev/null | head -5 || true)

        local cross_repo_learnings
        cross_repo_learnings=$(jq -r '
            .cross_repo_learnings // [] | .[-5:][] |
            "- [\(.repo // "unknown")] \(.type // "learning"): bugs=\(.bugs // 0), warnings=\(.warnings // 0)"
        ' "$GLOBAL_MEMORY" 2>/dev/null | head -5 || true)

        if [[ -n "$global_patterns" || -n "$cross_repo_learnings" ]]; then
            echo ""
            echo "## Cross-Repo Learnings (Global)"
            [[ -n "$global_patterns" ]] && echo "$global_patterns"
            [[ -n "$cross_repo_learnings" ]] && echo "$cross_repo_learnings"
        fi
    fi

    echo ""
    emit_event "memory.inject" "stage=${stage_id}"
}



# memory_capture_decision <type> <summary> <detail>
# Record a design decision / ADR.
memory_capture_decision() {
    local dec_type="${1:-decision}"
    local summary="${2:-}"
    local detail="${3:-}"

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local decisions_file="$mem_dir/decisions.json"

    local tmp_file
    tmp_file=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" RETURN
    jq --arg type "$dec_type" \
       --arg summary "$summary" \
       --arg detail "$detail" \
       --arg ts "$(now_iso)" \
       '.decisions += [{
           type: $type,
           summary: $summary,
           detail: $detail,
           recorded_at: $ts
       }] | .decisions = (.decisions | .[-100:])' \
       "$decisions_file" > "$tmp_file" && mv "$tmp_file" "$decisions_file"

    # Dual-write to DB
    if type db_save_decision >/dev/null 2>&1; then
        local rhash
        rhash="$(repo_hash)"
        db_save_decision "$rhash" "$dec_type" "${detail:-}" "$summary" "" 2>/dev/null || true
    fi

    memory_store_for_embedding "decision" "${dec_type}: ${summary} - ${detail:-}" "$(repo_hash)" 2>/dev/null || true

    emit_event "memory.decision" "type=${dec_type}" "summary=${summary:0:80}"
    success "Recorded decision: ${summary}"
}

# ─── CLI Display Commands ──────────────────────────────────────────────────

memory_show() {
    local show_global=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global) show_global=true; shift ;;
            *)        shift ;;
        esac
    done

    if [[ "$show_global" == "true" ]]; then
        echo ""
        echo -e "${PURPLE}${BOLD}━━━ Global Memory ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        if [[ -f "$GLOBAL_MEMORY" ]]; then
            local learning_count
            learning_count=$(jq '.cross_repo_learnings | length' "$GLOBAL_MEMORY" 2>/dev/null || echo 0)
            echo -e "  Cross-repo learnings: ${CYAN}${learning_count}${RESET}"
            echo ""
            if [[ "$learning_count" -gt 0 ]]; then
                jq -r '.cross_repo_learnings[-10:][] |
                    "  \(.repo) — \(.type) (\(.captured_at // "unknown"))"' \
                    "$GLOBAL_MEMORY" 2>/dev/null || true
            fi
        else
            echo -e "  ${DIM}No global memory yet.${RESET}"
        fi
        echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo ""
        return 0
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local repo
    repo="$(repo_name)"

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Memory: ${repo} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    # Patterns
    echo -e "${BOLD}  PROJECT${RESET}"
    if [[ -f "$mem_dir/patterns.json" ]]; then
        local proj_type framework lang pkg_mgr test_runner
        proj_type=$(jq -r '.project.type // "unknown"' "$mem_dir/patterns.json" 2>/dev/null)
        framework=$(jq -r '.project.framework // "-"' "$mem_dir/patterns.json" 2>/dev/null)
        lang=$(jq -r '.project.language // "-"' "$mem_dir/patterns.json" 2>/dev/null)
        pkg_mgr=$(jq -r '.project.package_manager // "-"' "$mem_dir/patterns.json" 2>/dev/null)
        test_runner=$(jq -r '.project.test_runner // "-"' "$mem_dir/patterns.json" 2>/dev/null)
        printf "    %-18s %s\n" "Type:" "$proj_type"
        printf "    %-18s %s\n" "Framework:" "$framework"
        printf "    %-18s %s\n" "Language:" "$lang"
        printf "    %-18s %s\n" "Package manager:" "$pkg_mgr"
        printf "    %-18s %s\n" "Test runner:" "$test_runner"
    else
        echo -e "    ${DIM}No patterns captured yet.${RESET}"
    fi
    echo ""

    # Failures
    echo -e "${BOLD}  FAILURE PATTERNS${RESET}"
    if [[ -f "$mem_dir/failures.json" ]]; then
        local failure_count
        failure_count=$(jq '.failures | length' "$mem_dir/failures.json" 2>/dev/null || echo 0)
        if [[ "$failure_count" -gt 0 ]]; then
            jq -r '.failures | sort_by(-.seen_count) | .[:5][] |
                "    [\(.stage)] \(.pattern[:80]) — seen \(.seen_count)x"' \
                "$mem_dir/failures.json" 2>/dev/null || true
        else
            echo -e "    ${DIM}No failures recorded.${RESET}"
        fi
    else
        echo -e "    ${DIM}No failures recorded.${RESET}"
    fi
    echo ""

    # Decisions
    echo -e "${BOLD}  DECISIONS${RESET}"
    if [[ -f "$mem_dir/decisions.json" ]]; then
        local decision_count
        decision_count=$(jq '.decisions | length' "$mem_dir/decisions.json" 2>/dev/null || echo 0)
        if [[ "$decision_count" -gt 0 ]]; then
            jq -r '.decisions[-5:][] |
                "    [\(.type)] \(.summary)"' \
                "$mem_dir/decisions.json" 2>/dev/null || true
        else
            echo -e "    ${DIM}No decisions recorded.${RESET}"
        fi
    else
        echo -e "    ${DIM}No decisions recorded.${RESET}"
    fi
    echo ""

    # Metrics
    echo -e "${BOLD}  BASELINES${RESET}"
    if [[ -f "$mem_dir/metrics.json" ]]; then
        local baseline_count
        baseline_count=$(jq '.baselines | length' "$mem_dir/metrics.json" 2>/dev/null || echo 0)
        if [[ "$baseline_count" -gt 0 ]]; then
            jq -r '.baselines | to_entries[] | "    \(.key): \(.value)"' \
                "$mem_dir/metrics.json" 2>/dev/null || true
        else
            echo -e "    ${DIM}No baselines tracked yet.${RESET}"
        fi
    else
        echo -e "    ${DIM}No baselines tracked yet.${RESET}"
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

memory_search() {
    if [[ "${1:-}" == "--semantic" ]]; then
        shift
        memory_semantic_search "$*" "" 10
        exit 0
    fi

    local keyword="${1:-}"

    if [[ -z "$keyword" ]]; then
        error "Usage: shipwright memory search <keyword>"
        echo -e "  ${DIM}Or: shipwright memory search --semantic <query>${RESET}"
        return 1
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local repo
    repo="$(repo_name)"

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Memory Search: \"${keyword}\" ━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    local found=0

    # ── Semantic search via intelligence (if available) ──
    if type intelligence_search_memory >/dev/null 2>&1; then
        local semantic_results
        semantic_results=$(intelligence_search_memory "$keyword" "$mem_dir" 5 2>/dev/null || echo "")
        if [[ -n "$semantic_results" ]] && echo "$semantic_results" | jq -e '.results | length > 0' >/dev/null 2>&1; then
            echo -e "  ${BOLD}${CYAN}Semantic Results (AI-ranked):${RESET}"
            local result_count
            result_count=$(echo "$semantic_results" | jq '.results | length')
            local i=0
            while [[ "$i" -lt "$result_count" ]]; do
                local file rel summary
                file=$(echo "$semantic_results" | jq -r ".results[$i].file // \"\"")
                rel=$(echo "$semantic_results" | jq -r ".results[$i].relevance // 0")
                summary=$(echo "$semantic_results" | jq -r ".results[$i].summary // \"\"")
                echo -e "    ${GREEN}●${RESET} [${rel}%] ${BOLD}${file}${RESET} — ${summary}"
                i=$((i + 1))
            done
            echo ""
            found=$((found + 1))

            # Also run grep search below for completeness
            echo -e "  ${DIM}Grep results (supplemental):${RESET}"
            echo ""
        fi
    fi

    # ── Grep-based search (fallback / supplemental) ──

    # Search patterns
    if [[ -f "$mem_dir/patterns.json" ]]; then
        local pattern_matches
        pattern_matches=$(grep -i "$keyword" "$mem_dir/patterns.json" 2>/dev/null || true)
        if [[ -n "$pattern_matches" ]]; then
            echo -e "  ${BOLD}Patterns:${RESET}"
            echo "$pattern_matches" | head -5 | sed 's/^/    /'
            echo ""
            found=$((found + 1))
        fi
    fi

    # Search failures
    if [[ -f "$mem_dir/failures.json" ]]; then
        local failure_matches
        failure_matches=$(jq -r --arg kw "$keyword" \
            '.failures[] | select(.pattern | test($kw; "i")) |
            "    [\(.stage)] \(.pattern[:80]) — seen \(.seen_count)x"' \
            "$mem_dir/failures.json" 2>/dev/null || true)
        if [[ -n "$failure_matches" ]]; then
            echo -e "  ${BOLD}Failures:${RESET}"
            echo "$failure_matches" | head -5
            echo ""
            found=$((found + 1))
        fi
    fi

    # Search decisions
    if [[ -f "$mem_dir/decisions.json" ]]; then
        local decision_matches
        decision_matches=$(jq -r --arg kw "$keyword" \
            '.decisions[] | select((.summary // "") | test($kw; "i")) |
            "    [\(.type)] \(.summary)"' \
            "$mem_dir/decisions.json" 2>/dev/null || true)
        if [[ -n "$decision_matches" ]]; then
            echo -e "  ${BOLD}Decisions:${RESET}"
            echo "$decision_matches" | head -5
            echo ""
            found=$((found + 1))
        fi
    fi

    # Search global memory
    if [[ -f "$GLOBAL_MEMORY" ]]; then
        local global_matches
        global_matches=$(grep -i "$keyword" "$GLOBAL_MEMORY" 2>/dev/null || true)
        if [[ -n "$global_matches" ]]; then
            echo -e "  ${BOLD}Global Memory:${RESET}"
            echo "$global_matches" | head -3 | sed 's/^/    /'
            echo ""
            found=$((found + 1))
        fi
    fi

    if [[ "$found" -eq 0 ]]; then
        echo -e "  ${DIM}No matches found for \"${keyword}\".${RESET}"
    fi

    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

memory_forget() {
    local forget_all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) forget_all=true; shift ;;
            *)     shift ;;
        esac
    done

    if [[ "$forget_all" == "true" ]]; then
        local mem_dir
        mem_dir="$(repo_memory_dir)"
        if [[ -d "$mem_dir" ]]; then
            rm -rf "$mem_dir"
            success "Cleared all memory for $(repo_name)"
            emit_event "memory.forget" "repo=$(repo_name)" "scope=all"
        else
            warn "No memory found for this repository."
        fi
    else
        error "Usage: shipwright memory forget --all"
        echo -e "  ${DIM}Use --all to confirm clearing memory for this repo.${RESET}"
        return 1
    fi
}

memory_export() {
    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"

    # Ensure all memory files exist (jq --slurpfile fails on missing files)
    for f in patterns.json failures.json decisions.json metrics.json; do
        [[ -f "$mem_dir/$f" ]] || echo '{}' > "$mem_dir/$f"
    done

    # Merge all memory files into a single JSON export
    local export_json
    export_json=$(jq -n \
        --arg repo "$(repo_name)" \
        --arg hash "$(repo_hash)" \
        --arg ts "$(now_iso)" \
        --slurpfile patterns "$mem_dir/patterns.json" \
        --slurpfile failures "$mem_dir/failures.json" \
        --slurpfile decisions "$mem_dir/decisions.json" \
        --slurpfile metrics "$mem_dir/metrics.json" \
        '{
            exported_at: $ts,
            repo: $repo,
            repo_hash: $hash,
            patterns: $patterns[0],
            failures: $failures[0],
            decisions: $decisions[0],
            metrics: $metrics[0]
        }')

    echo "$export_json"
    emit_event "memory.export" "repo=$(repo_name)"
}

memory_import() {
    local import_file="${1:-}"

    if [[ -z "$import_file" || ! -f "$import_file" ]]; then
        error "Usage: shipwright memory import <file.json>"
        return 1
    fi

    # Validate JSON
    if ! jq empty "$import_file" 2>/dev/null; then
        error "Invalid JSON file: $import_file"
        return 1
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"

    # Extract and write each section
    local tmp_file
    tmp_file=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" RETURN

    jq '.patterns // {}' "$import_file" > "$tmp_file" && mv "$tmp_file" "$mem_dir/patterns.json"
    jq '.failures // {"failures":[]}' "$import_file" > "$tmp_file" && mv "$tmp_file" "$mem_dir/failures.json"
    jq '.decisions // {"decisions":[]}' "$import_file" > "$tmp_file" && mv "$tmp_file" "$mem_dir/decisions.json"
    jq '.metrics // {"baselines":{}}' "$import_file" > "$tmp_file" && mv "$tmp_file" "$mem_dir/metrics.json"

    success "Imported memory from ${import_file}"
    emit_event "memory.import" "repo=$(repo_name)" "file=${import_file}"
}

memory_stats() {
    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local repo
    repo="$(repo_name)"

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Memory Stats: ${repo} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    # Size
    local total_size=0
    for f in "$mem_dir"/*.json; do
        if [[ -f "$f" ]]; then
            local fsize
            fsize=$(wc -c < "$f" | tr -d ' ')
            total_size=$((total_size + fsize))
        fi
    done

    local size_human
    if [[ "$total_size" -ge 1048576 ]]; then
        size_human="$(echo "$total_size" | awk '{printf "%.1fMB", $1/1048576}')"
    elif [[ "$total_size" -ge 1024 ]]; then
        size_human="$(echo "$total_size" | awk '{printf "%.1fKB", $1/1024}')"
    else
        size_human="${total_size}B"
    fi

    echo -e "  ${BOLD}Storage${RESET}"
    printf "    %-18s %s\n" "Total size:" "$size_human"
    printf "    %-18s %s\n" "Location:" "$mem_dir"
    echo ""

    # Counts
    local failure_count decision_count baseline_count known_issue_count
    failure_count=$(jq '.failures | length' "$mem_dir/failures.json" 2>/dev/null || echo 0)
    decision_count=$(jq '.decisions | length' "$mem_dir/decisions.json" 2>/dev/null || echo 0)
    baseline_count=$(jq '.baselines | length' "$mem_dir/metrics.json" 2>/dev/null || echo 0)
    known_issue_count=$(jq '.known_issues // [] | length' "$mem_dir/patterns.json" 2>/dev/null || echo 0)

    echo -e "  ${BOLD}Contents${RESET}"
    printf "    %-18s %s\n" "Failure patterns:" "$failure_count"
    printf "    %-18s %s\n" "Decisions:" "$decision_count"
    printf "    %-18s %s\n" "Baselines:" "$baseline_count"
    printf "    %-18s %s\n" "Known issues:" "$known_issue_count"
    echo ""

    # Age — oldest captured_at
    local captured_at
    captured_at=$(jq -r '.captured_at // ""' "$mem_dir/patterns.json" 2>/dev/null || echo "")
    if [[ -n "$captured_at" && "$captured_at" != "null" ]]; then
        printf "    %-18s %s\n" "First captured:" "$captured_at"
    fi

    # Event-based hit rate
    local inject_count capture_count
    if [[ -f "$EVENTS_FILE" ]]; then
        inject_count=$(grep -c '"memory.inject"' "$EVENTS_FILE" 2>/dev/null || true)
        inject_count="${inject_count:-0}"
        capture_count=$(grep -c '"memory.capture"' "$EVENTS_FILE" 2>/dev/null || true)
        capture_count="${capture_count:-0}"
        echo ""
        echo -e "  ${BOLD}Usage${RESET}"
        printf "    %-18s %s\n" "Context injections:" "$inject_count"
        printf "    %-18s %s\n" "Pipeline captures:" "$capture_count"
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# ─── A/B Testing Framework ─────────────────────────────────────────────────
# Test memory system effectiveness by randomly assigning control vs treatment.
#   - Control: pipeline runs without memory injection
#   - Treatment: pipeline runs with memory injection
# Emits events to track metrics: iterations, cost, test_failures, completion_status

AB_RESULTS_DIR="${HOME}/.shipwright/memory"
AB_RESULTS_FILE="${AB_RESULTS_DIR}/ab-results.jsonl"

# Assign control or treatment for this pipeline run
#   Returns: "control" or "treatment"
memory_ab_assign_group() {
    local ab_ratio="${1:-0.2}"  # Read from daemon-config intelligence.ab_test_ratio

    # Validate ratio is between 0 and 1
    if ! echo "$ab_ratio" | grep -qE '^0(\.[0-9]+)?$|^1(\.0+)?$'; then
        ab_ratio="0.2"
    fi

    # Generate random 0-100
    local rand=$((RANDOM % 100))
    local threshold
    threshold=$(echo "$ab_ratio * 100" | bc 2>/dev/null || echo "20")
    threshold=${threshold%.*}  # Remove decimal

    if [[ "$rand" -lt "$threshold" ]]; then
        echo "control"
    else
        echo "treatment"
    fi
}

# Record A/B test assignment at pipeline start
#   $1: pipeline_id
#   $2: group (control|treatment)
memory_ab_record_assignment() {
    local pipeline_id="$1"
    local group="${2:-}"

    [[ -z "$pipeline_id" || -z "$group" ]] && return 1

    # Emit event for tracking
    emit_event "memory.ab_assigned" \
        "pipeline_id=$pipeline_id" \
        "group=$group" \
        "timestamp=$(now_iso)"

    return 0
}

# Record A/B test result after pipeline completion
#   $1: pipeline_id
#   $2: group (control|treatment)
#   $3: iterations (number of build iterations)
#   $4: cost (estimated token cost)
#   $5: test_failures (number of test failures)
#   $6: completion_status (success|failure)
memory_ab_record_result() {
    local pipeline_id="$1"
    local group="$2"
    local iterations="$3"
    local cost="$4"
    local test_failures="$5"
    local completion_status="$6"

    [[ -z "$pipeline_id" || -z "$group" ]] && return 1

    mkdir -p "$AB_RESULTS_DIR"

    # Record result as JSONL
    local result_json
    result_json=$(jq -n \
        --arg pipeline_id "$pipeline_id" \
        --arg group "$group" \
        --arg timestamp "$(now_iso)" \
        --arg iterations "$iterations" \
        --arg cost "$cost" \
        --arg test_failures "$test_failures" \
        --arg completion_status "$completion_status" \
        '{
            pipeline_id: $pipeline_id,
            group: $group,
            timestamp: $timestamp,
            iterations: ($iterations | tonumber? // 0),
            cost: ($cost | tonumber? // 0),
            test_failures: ($test_failures | tonumber? // 0),
            completion_status: $completion_status
        }')

    echo "$result_json" >> "$AB_RESULTS_FILE"

    # Emit event
    emit_event "memory.ab_result" \
        "pipeline_id=$pipeline_id" \
        "group=$group" \
        "iterations=$iterations" \
        "cost=$cost" \
        "test_failures=$test_failures" \
        "completion_status=$completion_status"

    return 0
}

# Generate A/B test report comparing control vs treatment
cmd_memory_ab_report() {
    if [[ ! -f "$AB_RESULTS_FILE" ]]; then
        warn "No A/B test results found at $AB_RESULTS_FILE"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        error "jq required for A/B report generation"
        return 1
    fi

    info "Memory A/B Test Report"
    echo ""

    local control_count treatment_count
    control_count=$(grep -c '"control"' "$AB_RESULTS_FILE" 2>/dev/null || echo "0")
    treatment_count=$(grep -c '"treatment"' "$AB_RESULTS_FILE" 2>/dev/null || echo "0")

    echo -e "${BOLD}Sample Sizes${RESET}"
    printf "  Control:   %3d pipelines\n" "$control_count"
    printf "  Treatment: %3d pipelines\n" "$treatment_count"
    echo ""

    # Calculate metrics for control group
    local control_data
    control_data=$(grep '"control"' "$AB_RESULTS_FILE" 2>/dev/null | jq -s '
        if length == 0 then
            {count: 0, avg_iterations: 0, avg_cost: 0, success_rate: 0}
        else
            {
                count: length,
                avg_iterations: ([.[].iterations // 0] | add / length | floor),
                avg_cost: ([.[].cost // 0] | add / length | floor),
                success_rate: (([.[] | select(.completion_status == "success")] | length) / length * 100 | floor)
            }
        end
    ' || echo '{"count": 0, "avg_iterations": 0, "avg_cost": 0, "success_rate": 0}')

    # Calculate metrics for treatment group
    local treatment_data
    treatment_data=$(grep '"treatment"' "$AB_RESULTS_FILE" 2>/dev/null | jq -s '
        if length == 0 then
            {count: 0, avg_iterations: 0, avg_cost: 0, success_rate: 0}
        else
            {
                count: length,
                avg_iterations: ([.[].iterations // 0] | add / length | floor),
                avg_cost: ([.[].cost // 0] | add / length | floor),
                success_rate: (([.[] | select(.completion_status == "success")] | length) / length * 100 | floor)
            }
        end
    ' || echo '{"count": 0, "avg_iterations": 0, "avg_cost": 0, "success_rate": 0}')

    # Extract values
    local c_iterations t_iterations c_cost t_cost c_success t_success
    c_iterations=$(echo "$control_data" | jq -r '.avg_iterations // 0')
    t_iterations=$(echo "$treatment_data" | jq -r '.avg_iterations // 0')
    c_cost=$(echo "$control_data" | jq -r '.avg_cost // 0')
    t_cost=$(echo "$treatment_data" | jq -r '.avg_cost // 0')
    c_success=$(echo "$control_data" | jq -r '.success_rate // 0')
    t_success=$(echo "$treatment_data" | jq -r '.success_rate // 0')

    # Calculate deltas
    local iter_delta cost_delta success_delta
    iter_delta=$((c_iterations - t_iterations))
    cost_delta=$((c_cost - t_cost))
    success_delta=$((t_success - c_success))

    # Direction indicators
    local iter_dir cost_dir success_dir
    [[ $iter_delta -gt 0 ]] && iter_dir="${GREEN}↓${RESET}" || iter_dir="${RED}↑${RESET}"
    [[ $cost_delta -gt 0 ]] && cost_dir="${GREEN}↓${RESET}" || cost_dir="${RED}↑${RESET}"
    [[ $success_delta -gt 0 ]] && success_dir="${GREEN}↑${RESET}" || success_dir="${RED}↓${RESET}"

    echo -e "${BOLD}Metrics${RESET}"
    echo ""
    printf "  %-28s %10s %10s %10s\n" "Metric" "Control" "Treatment" "Delta"
    printf "  %s\n" "$(printf '%.0s-' {1..60})"
    printf "  %-28s %10d %10d %10s %s\n" "Avg Iterations" "$c_iterations" "$t_iterations" "$iter_delta" "$iter_dir"
    printf "  %-28s %10d %10d %10s %s\n" "Avg Cost (tokens)" "$c_cost" "$t_cost" "$cost_delta" "$cost_dir"
    printf "  %-28s %10d%% %10d%% %10s %s\n" "Success Rate" "$c_success" "$t_success" "$success_delta" "$success_dir"
    echo ""

    # Summary
    echo -e "${BOLD}Summary${RESET}"
    if [[ $iter_delta -gt 0 ]]; then
        success "Memory injection reduces iterations by ${iter_delta} (${GREEN}$(echo "scale=1; $iter_delta * 100 / $c_iterations" | bc)% improvement${RESET})"
    elif [[ $iter_delta -lt 0 ]]; then
        warn "Memory injection increases iterations by $((iter_delta * -1)) (regression)"
    else
        info "No significant difference in iteration count"
    fi

    if [[ $cost_delta -gt 0 ]]; then
        success "Memory injection reduces cost by ${cost_delta} tokens (${GREEN}$(echo "scale=1; $cost_delta * 100 / $c_cost" | bc)% savings${RESET})"
    elif [[ $cost_delta -lt 0 ]]; then
        warn "Memory injection increases cost by $((cost_delta * -1)) tokens (regression)"
    fi

    if [[ $success_delta -gt 0 ]]; then
        success "Memory injection improves success rate by ${success_delta}pp (${GREEN}$(echo "scale=1; $success_delta" | bc)% better${RESET})"
    elif [[ $success_delta -lt 0 ]]; then
        warn "Memory injection reduces success rate by $((success_delta * -1))pp (regression)"
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# ─── Help ──────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright memory${RESET} ${DIM}v${VERSION}${RESET} — Persistent Learning & Context System"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright memory${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}show${RESET}               Display memory for current repo"
    echo -e "  ${CYAN}show${RESET} --global       Display cross-repo learnings"
    echo -e "  ${CYAN}search${RESET} <keyword>    Search memory for keyword"
    echo -e "  ${CYAN}search${RESET} --semantic <query>  Semantic search via memory_embeddings"
    echo -e "  ${CYAN}forget${RESET} --all         Clear memory for current repo"
    echo -e "  ${CYAN}export${RESET}              Export memory as JSON"
    echo -e "  ${CYAN}import${RESET} <file>        Import memory from JSON"
    echo -e "  ${CYAN}stats${RESET}               Show memory size, age, hit rate"
    echo ""
    echo -e "${BOLD}PIPELINE INTEGRATION${RESET}"
    echo -e "  ${CYAN}capture${RESET} <state> <artifacts>    Capture pipeline learnings"
    echo -e "  ${CYAN}inject${RESET} <stage_id>              Inject context for a stage"
    echo -e "  ${CYAN}pattern${RESET} <type> [data]           Record a codebase pattern"
    echo -e "  ${CYAN}metric${RESET} <name> <value>           Update a performance baseline"
    echo -e "  ${CYAN}decision${RESET} <type> <summary>       Record a design decision"
    echo -e "  ${CYAN}analyze-failure${RESET} <log> <stage>    Analyze failure root cause via AI"
    echo -e "  ${CYAN}fix-outcome${RESET} <pattern> <applied> <resolved>  Record fix effectiveness"
    echo -e "  ${CYAN}ab-report${RESET}                      Compare control vs treatment in A/B tests"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright memory show${RESET}                            # View repo memory"
    echo -e "  ${DIM}shipwright memory show --global${RESET}                   # View cross-repo learnings"
    echo -e "  ${DIM}shipwright memory search \"auth\"${RESET}                   # Find auth-related memories"
    echo -e "  ${DIM}shipwright memory export > backup.json${RESET}            # Export memory"
    echo -e "  ${DIM}shipwright memory import backup.json${RESET}              # Import memory"
    echo -e "  ${DIM}shipwright memory capture .claude/pipeline-state.md .claude/pipeline-artifacts${RESET}"
    echo -e "  ${DIM}shipwright memory inject build${RESET}                    # Get context for build stage"
}

# ─── Weighted Search (RL integration) ──────────────────────────────────────

# Search memory with recency + success weighting.
# Args: $1=query, $2=memory_dir (optional), $3=max_results (default 5)
# Returns JSON array of results with recency_weight applied.
memory_search_weighted() {
    local query="${1:-}"
    local memory_dir="${2:-}"
    local max_results="${3:-5}"

    if [[ -z "$memory_dir" ]] && type repo_memory_dir >/dev/null 2>&1; then
        memory_dir="$(repo_memory_dir)"
    fi
    memory_dir="${memory_dir:-$HOME/.shipwright/memory}"

    if [[ ! -d "$memory_dir" ]]; then
        echo "[]"
        return 0
    fi

    # Get base ranked results
    local base_results
    base_results="$(memory_ranked_search "$query" "$memory_dir" "$max_results" 2>/dev/null || echo "[]")"

    if [[ "$base_results" == "[]" ]] || [[ -z "$base_results" ]]; then
        echo "[]"
        return 0
    fi

    # Apply recency weighting: boost results from files modified recently
    local now_epoch
    now_epoch="$(date +%s)"

    echo "$base_results" | jq --argjson now "$now_epoch" '
        [.[] | . + {
            recency_weight: (
                if .timestamp then
                    (($now - (.timestamp // $now)) / 86400) as $age |
                    if $age <= 7 then 1.5
                    elif $age <= 30 then 1.0
                    elif $age <= 90 then 0.7
                    else 0.4 end
                else 0.8 end
            )
        }] |
        [.[] | .combined_score = ((.relevance // 50) * .recency_weight)] |
        sort_by(-.combined_score)
    ' 2>/dev/null || echo "$base_results"
}

# Reduce weight of memory entries older than threshold.
# Args: $1=days_threshold (default 30), $2=memory_dir (optional)
memory_decay_old() {
    local days_threshold="${1:-30}"
    local memory_dir="${2:-}"

    if [[ -z "$memory_dir" ]] && type repo_memory_dir >/dev/null 2>&1; then
        memory_dir="$(repo_memory_dir)"
    fi
    memory_dir="${memory_dir:-$HOME/.shipwright/memory}"

    if [[ ! -d "$memory_dir" ]]; then
        return 0
    fi

    local now_epoch decayed_count
    now_epoch="$(date +%s)"
    decayed_count=0
    local threshold_epoch
    threshold_epoch=$(( now_epoch - (days_threshold * 86400) ))

    # Process failure patterns file if it exists
    local failures_file="${memory_dir}/failures.json"
    if [[ -f "$failures_file" ]]; then
        local tmp
        tmp="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/mem-decay-$$.tmp")"
        jq --argjson threshold "$threshold_epoch" --argjson half "$days_threshold" '
            if type == "array" then
                [.[] | if (.timestamp // 0) < $threshold then
                    .weight = ((.weight // 1) * 0.5 | if . < 0.1 then 0.1 else . end)
                else . end]
            else . end
        ' "$failures_file" > "$tmp" 2>/dev/null
        if [[ -s "$tmp" ]]; then
            mv "$tmp" "$failures_file"
            decayed_count=$((decayed_count + 1))
        else
            rm -f "$tmp"
        fi
    fi

    # Process decisions file if it exists
    local decisions_file="${memory_dir}/decisions.json"
    if [[ -f "$decisions_file" ]]; then
        local tmp
        tmp="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/mem-decay2-$$.tmp")"
        jq --argjson threshold "$threshold_epoch" '
            if type == "array" then
                [.[] | if (.timestamp // 0) < $threshold then
                    .weight = ((.weight // 1) * 0.5 | if . < 0.1 then 0.1 else . end)
                else . end]
            else . end
        ' "$decisions_file" > "$tmp" 2>/dev/null
        if [[ -s "$tmp" ]]; then
            mv "$tmp" "$decisions_file"
            decayed_count=$((decayed_count + 1))
        else
            rm -f "$tmp"
        fi
    fi

    if [[ "$decayed_count" -gt 0 ]]; then
        emit_event "memory.decay_applied" "files=$decayed_count" "threshold_days=$days_threshold"
    fi
}

# ─── Command Router ─────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    SUBCOMMAND="${1:-help}"
    shift 2>/dev/null || true

    case "$SUBCOMMAND" in
        show)
            memory_show "$@"
            ;;
        search)
            memory_search "$@"
            ;;
        forget)
            memory_forget "$@"
            ;;
        export)
            memory_export
            ;;
        import)
            memory_import "$@"
            ;;
        stats)
            memory_stats
            ;;
        capture)
            memory_capture_pipeline "$@"
            ;;
        inject)
            memory_inject_context "$@"
            ;;
        pattern)
            memory_capture_pattern "$@"
            ;;
        get)
            memory_get_baseline "$@"
            ;;
        metric)
            memory_update_metrics "$@"
            ;;
        decision)
            memory_capture_decision "$@"
            ;;
        analyze-failure)
            memory_analyze_failure "$@"
            ;;
        fix-outcome)
            memory_record_fix_outcome "$@"
            ;;
        search-weighted)
            memory_search_weighted "$@"
            ;;
        decay)
            memory_decay_old "$@"
            ;;
        ab-report)
            cmd_memory_ab_report "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: ${SUBCOMMAND}"
            echo ""
            show_help
            exit 1
            ;;
    esac
fi
