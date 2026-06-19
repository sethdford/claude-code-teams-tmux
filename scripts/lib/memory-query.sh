#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/memory-query — Ranked memory search (extracted core)        ║
# ║  Owns query tokenization, the L1 cache fast-path, and the ranked full      ║
# ║  scan over failures/decisions/patterns. Fail-open by contract: every       ║
# ║  error degrades to a correct (possibly slower) result, never a non-zero    ║
# ║  exit into the pipeline.                                                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Extracted verbatim from sw-memory.sh to shrink the monolith and give the
# query path a testable home (see design.md "Interface Contracts"). Behavior is
# byte-identical to the pre-extraction implementation for the same
# (query, dir, max, corpus).
#
# Public interface:
#   memory_ranked_search <query> <dir> [max=5]  -> stdout: JSON array; exit ALWAYS 0
#
# Internal helpers:
#   _expand_domain_keywords <text>   -> stdout: text + semantic expansions
#   _memory_query_keywords  <query>  -> stdout: tokenized/stopword-stripped/expanded keywords
#   _memory_query_now_ms             -> stdout: epoch milliseconds (GNU/BSD-safe)

# Guard against double-sourcing.
[[ -n "${_MEMORY_QUERY_LOADED:-}" ]] && return 0 2>/dev/null || true
_MEMORY_QUERY_LOADED=1

# ─── Minimal fallbacks (when sourced standalone, e.g. unit tests) ────────────
if [[ "$(type -t info 2>/dev/null)" != "function" ]]; then
    info() { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
    emit_event() { :; }  # no-op when canonical helper absent
fi

# Source the L2 index and L1 cache modules when they aren't already loaded, so
# this module works standalone. Both are fail-open: absence degrades to a full
# scan with no cache, exactly as before.
_MQ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(type -t memory_index_version 2>/dev/null)" != "function" ]]; then
    [[ -f "$_MQ_DIR/memory-index.sh" ]] && source "$_MQ_DIR/memory-index.sh"
fi
if [[ "$(type -t memory_cache_get 2>/dev/null)" != "function" ]]; then
    [[ -f "$_MQ_DIR/memory-cache.sh" ]] && source "$_MQ_DIR/memory-cache.sh"
fi
unset _MQ_DIR

# ─── Portable epoch milliseconds (GNU %N, fall back on BSD/no-%N) ─────────────
# GNU date emits 19 digits (s+ns); divide to ms. BSD date emits a literal "N"
# which fails the all-digit guard → fall back to whole-second precision.
_memory_query_now_ms() {
    local ns
    ns=$(date +%s%N 2>/dev/null || echo "")
    if [[ "$ns" =~ ^[0-9]{16,}$ ]]; then
        echo $(( ns / 1000000 ))
    elif command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000)' 2>/dev/null || echo $(( $(date +%s) * 1000 ))
    else
        echo $(( $(date +%s) * 1000 ))
    fi
}

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

# ─── Query tokenization ──────────────────────────────────────────────────────
# lowercase → split on non-alphanumeric → unique → drop len<=2 + stopwords →
# domain-expand. Output is a newline-separated keyword list (may be empty).
_memory_query_keywords() {
    local query="$1" keywords
    keywords=$(echo "$query" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u | \
        grep -vxE '^.{1,2}$|^(the|and|for|not|with|this|that|from)$' || true)
    keywords=$(_expand_domain_keywords "$keywords" 2>/dev/null || echo "$keywords")
    printf '%s' "$keywords"
}

# ─── L2 index candidate narrowing ────────────────────────────────────────────
# Emits deduped "<source_type>:<idx>" refs for entries that COULD score > 0,
# or the literal "ALL" when the index is unusable (→ caller does a full scan).
#
# Parity contract: the scan scores a keyword via `grep -qiF "$kw"` (substring of
# the entry text). Each query keyword is all-alphanumeric, so it can only match
# *inside a single token* — therefore "kw is a substring of the text" iff "some
# index token contains kw". We match candidates by SUBSTRING over the index keys
# (not exact `memory_index_lookup`), which makes the narrowed set a provable
# superset of the substring matches. Over-inclusion is harmless: the authoritative
# per-entry scorer drops anything that scores 0. High-effectiveness failures
# (boosted +2 even with zero keyword hits) are unioned in unconditionally.
_memory_query_candidates() {
    local dir="$1" keywords="$2"
    local idx="$dir/index.json"
    command -v jq >/dev/null 2>&1 || { echo "ALL"; return 0; }
    if [[ "$(type -t memory_index_validate 2>/dev/null)" != "function" ]]; then
        echo "ALL"; return 0
    fi
    if ! memory_index_validate "$dir" 2>/dev/null; then
        memory_index_build "$dir" >/dev/null 2>&1 || { echo "ALL"; return 0; }
    fi
    [[ -f "$idx" ]] || { echo "ALL"; return 0; }

    local refs="" kw hits
    while IFS= read -r kw; do
        [[ -z "$kw" ]] && continue
        # Multi-word domain-expansion lines never match via grep -qiF (tokens are
        # single words), so they contribute no candidates — matching legacy behavior.
        case "$kw" in *[[:space:]]*) continue;; esac
        hits=$(jq -r --arg kw "$kw" \
            '.keywords | to_entries[] | select(.key | contains($kw)) | .value[]' \
            "$idx" 2>/dev/null) || true
        [[ -n "$hits" ]] && refs="${refs}${hits}"$'\n'
    done <<< "$keywords"

    # Always include high-effectiveness failures (loose >50; the scorer re-checks).
    if [[ -f "$dir/failures.json" ]]; then
        local eff
        eff=$(jq -r \
            '.failures | to_entries[] | select(((.value.fix_effectiveness_rate // 0) | tonumber? // 0) > 50) | "failure:\(.key)"' \
            "$dir/failures.json" 2>/dev/null) || true
        [[ -n "$eff" ]] && refs="${refs}${eff}"$'\n'
    fi

    # Deduped, validated refs. Empty output is meaningful: "no candidates" → an
    # empty narrowed scan, distinct from the "ALL" full-scan sentinel above.
    printf '%s' "$refs" | grep -E '^(failure|decision|pattern):[0-9]+$' | sort -u || true
}

# ─── Per-entry scorers (authoritative; shared by full-scan and narrowed paths) ─
# Echo "<score>|<json-line>" when score > 0, else nothing. Logic is byte-identical
# to the original inline scan so both paths emit the exact same lines.
_mq_score_failure_entry() {
    local entry="$1" keywords="$2"
    [[ -z "$entry" ]] && return 0
    local entry_text
    entry_text=$(echo "$entry" | jq -r '(.pattern // "") + " " + (.root_cause // "") + " " + (.fix // "")' 2>/dev/null)
    local score=0 kw
    while IFS= read -r kw; do
        [[ -z "$kw" ]] && continue
        if echo "$entry_text" | grep -qiF "$kw" 2>/dev/null; then
            score=$((score + 1))
        fi
    done <<< "$keywords"

    local effectiveness
    effectiveness=$(echo "$entry" | jq -r '.fix_effectiveness_rate // 0' 2>/dev/null)
    if [[ "$effectiveness" =~ ^[0-9]+$ ]] && [[ "$effectiveness" -gt 50 ]]; then
        score=$((score + 2))
    fi

    if [[ "$score" -gt 0 ]]; then
        local content
        content=$(echo "$entry" | jq -r '(.pattern // "") + " | " + (.root_cause // "") + " | " + (.fix // "")' 2>/dev/null)
        echo "${score}|{\"source_type\":\"failure\",\"content_text\":$(echo "$content" | jq -Rs .)}"
    fi
}

_mq_score_decision_entry() {
    local entry="$1" keywords="$2"
    [[ -z "$entry" ]] && return 0
    local entry_text
    entry_text=$(echo "$entry" | jq -r '(.summary // "") + " " + (.detail // "") + " " + (.type // "")' 2>/dev/null)
    local score=0 kw
    while IFS= read -r kw; do
        [[ -z "$kw" ]] && continue
        echo "$entry_text" | grep -qiF "$kw" 2>/dev/null && score=$((score + 1))
    done <<< "$keywords"
    if [[ "$score" -gt 0 ]]; then
        local content
        content=$(echo "$entry" | jq -r '(.summary // "") + " | " + (.detail // "")' 2>/dev/null)
        echo "${score}|{\"source_type\":\"decision\",\"content_text\":$(echo "$content" | jq -Rs .)}"
    fi
}

# ─── TF-IDF-like ranked search across failures, patterns, decisions ──────────
# Returns JSON array of {source_type, content_text} for injection compatibility.
memory_ranked_search() {
    local query="$1"
    local memory_dir="$2"
    local max_results="${3:-5}"
    local _t_start; _t_start=$(_memory_query_now_ms)

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

    # ── L1 cache: return a byte-identical prior result when one is fresh ──
    # Keyed by query + source-version, so any memory write invalidates it.
    # Disable with SW_MEMORY_CACHE=0. Fail-open: a miss runs the full scan.
    if [[ "${SW_MEMORY_CACHE:-1}" != "0" ]] && \
       [[ "$(type -t memory_cache_get 2>/dev/null)" == "function" ]]; then
        local _cached
        if _cached="$(memory_cache_get "$memory_dir" "$query" "$max_results")"; then
            emit_event "memory.cache_hit" "dir=$memory_dir" "max=$max_results"
            emit_event "memory.query_time" "ms=$(( $(_memory_query_now_ms) - _t_start ))" "hit=1" "path=cache"
            printf '%s\n' "$_cached"
            return 0
        fi
    fi

    # Extract and expand query keywords
    local keywords
    keywords=$(_memory_query_keywords "$query")

    local results_file
    results_file=$(mktemp)

    # ── L2 index: narrow the O(N) failure/decision scans to candidate entries ──
    # Gated by SW_MEMORY_INDEX (default on). "ALL" (or index off) → legacy full
    # scan. Patterns.json is one synthetic entry (O(1)) so it is always scanned.
    local candidates="ALL"
    if [[ "${SW_MEMORY_INDEX:-1}" != "0" ]]; then
        candidates="$(_memory_query_candidates "$memory_dir" "$keywords")"
        [[ -z "$candidates" ]] && candidates="NONE"  # index usable, zero matches
    fi

    # Search failures.json
    if [[ -f "$memory_dir/failures.json" ]]; then
        if [[ "$candidates" == "ALL" ]]; then
            jq -c '.failures[]? // empty' "$memory_dir/failures.json" 2>/dev/null | while IFS= read -r entry; do
                local line; line=$(_mq_score_failure_entry "$entry" "$keywords")
                [[ -n "$line" ]] && echo "$line" >> "$results_file"
            done
        elif [[ "$candidates" != "NONE" ]]; then
            while IFS= read -r i; do
                [[ -z "$i" ]] && continue
                local entry; entry=$(jq -c ".failures[$i] // empty" "$memory_dir/failures.json" 2>/dev/null)
                local line; line=$(_mq_score_failure_entry "$entry" "$keywords")
                [[ -n "$line" ]] && echo "$line" >> "$results_file"
            done < <(printf '%s\n' "$candidates" | sed -n 's/^failure:\([0-9]*\)$/\1/p' | sort -n)
        fi
    fi

    # Search decisions.json
    if [[ -f "$memory_dir/decisions.json" ]]; then
        if [[ "$candidates" == "ALL" ]]; then
            jq -c '.decisions[]? // empty' "$memory_dir/decisions.json" 2>/dev/null | while IFS= read -r entry; do
                local line; line=$(_mq_score_decision_entry "$entry" "$keywords")
                [[ -n "$line" ]] && echo "$line" >> "$results_file"
            done
        elif [[ "$candidates" != "NONE" ]]; then
            while IFS= read -r i; do
                [[ -z "$i" ]] && continue
                local entry; entry=$(jq -c ".decisions[$i] // empty" "$memory_dir/decisions.json" 2>/dev/null)
                local line; line=$(_mq_score_decision_entry "$entry" "$keywords")
                [[ -n "$line" ]] && echo "$line" >> "$results_file"
            done < <(printf '%s\n' "$candidates" | sed -n 's/^decision:\([0-9]*\)$/\1/p' | sort -n)
        fi
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
        # Sort to a file first, then `head` it — never pipe `head` directly
        # downstream of `sort`. Under inherited `set -o pipefail`, `head` closing
        # early on a large result set sends SIGPIPE to `sort` (exit 141), which
        # would make the pipeline "fail" and collapse the output to "[]"
        # non-deterministically (only when sort is still writing). Reading from a
        # file gives `head` no upstream process to signal.
        local sorted_file="${results_file}.sorted"
        sort -t'|' -k1 -rn "$results_file" > "$sorted_file" 2>/dev/null || true
        output=$(head -"$max_results" "$sorted_file" 2>/dev/null | cut -d'|' -f2- | jq -s '.' 2>/dev/null)
        [[ -z "$output" ]] && output="[]"
        rm -f "$sorted_file" 2>/dev/null || true
    else
        output="[]"
    fi
    rm -f "$results_file" 2>/dev/null || true

    # ── L1 cache: memoize this exact output for repeat queries ──
    if [[ "${SW_MEMORY_CACHE:-1}" != "0" ]] && \
       [[ "$(type -t memory_cache_put 2>/dev/null)" == "function" ]]; then
        memory_cache_put "$memory_dir" "$query" "$max_results" "$output" || true
    fi

    emit_event "memory.query_time" "ms=$(( $(_memory_query_now_ms) - _t_start ))" "hit=0" "path=scan"
    echo "$output"
}
