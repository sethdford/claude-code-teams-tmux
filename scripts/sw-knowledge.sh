#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright knowledge — Fleet-Wide Pattern Mining & Knowledge Transfer    ║
# ║  Mines per-repo memory across the fleet, consolidates recurring patterns  ║
# ║  by cross-repo signature, scores fleet confidence, and transfers/injects  ║
# ║  the knowledge into new pipelines.                                        ║
# ║  Commands: mine, transfer, inject, search, show, report                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# shellcheck disable=SC2034
VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Dependency check ─────────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: sw-knowledge.sh requires 'jq'. Install with: brew install jq (macOS) or apt install jq (Linux)" >&2
    exit 1
fi

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events, atomic writes)
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
    # shellcheck disable=SC2155
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
# atomic_write fallback (tmp file + mv)
if [[ "$(type -t atomic_write 2>/dev/null)" != "function" ]]; then
  atomic_write() {
    local target="$1" data="$2" tmp
    [[ -z "$target" ]] && { error "atomic_write: target file not specified"; return 1; }
    tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
    printf '%s' "$data" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$target" || { rm -f "$tmp"; return 1; }
    return 0
  }
fi

# ─── Storage ────────────────────────────────────────────────────────────────
MEMORY_ROOT="${HOME}/.shipwright/memory"
FLEET_KNOWLEDGE_FILE="${MEMORY_ROOT}/fleet-knowledge.json"
GLOBAL_FILE="${MEMORY_ROOT}/global.json"

# Minimum number of distinct repos a pattern must recur in to be considered
# "fleet-wide" (eligible for transfer into global.json).
KM_CROSS_REPO_THRESHOLD="${KM_CROSS_REPO_THRESHOLD:-2}"
# Cap on how many patterns are promoted into global.json per transfer.
KM_TRANSFER_CAP="${KM_TRANSFER_CAP:-50}"

# ─── Success-pattern store (separate from failure knowledge) ────────────────
# Mines *successful* pipeline configurations (template, iterations, cost,
# complexity) from the event log into a distinct schema-v1 document. The event
# log (~/.shipwright/events.jsonl) is the source of truth — the library
# regenerates fully on every mine, so a corrupt/deleted file self-heals.
FLEET_PATTERNS_FILE="${HOME}/.shipwright/fleet-patterns.json"
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"
# A recommendation must score at least this (0-100) to be surfaced.
SW_FLEET_RECOMMEND_THRESHOLD="${SW_FLEET_RECOMMEND_THRESHOLD:-60}"
# Minimum successful applications before a pattern is trustworthy enough to
# recommend (guards against one-off flukes).
SW_FLEET_MIN_APPLIED="${SW_FLEET_MIN_APPLIED:-2}"
# Minimum success rate (%) before a pattern is recommendable.
SW_FLEET_MIN_SUCCESS_RATE="${SW_FLEET_MIN_SUCCESS_RATE:-50}"

# ─── Helpers ──────────────────────────────────────────────────────────────

ensure_memory_root() {
    mkdir -p "$MEMORY_ROOT"
}

# Seed an empty fleet-knowledge.json structure if missing.
ensure_knowledge_file() {
    ensure_memory_root
    if [[ ! -f "$FLEET_KNOWLEDGE_FILE" ]] || ! jq -e '.patterns' "$FLEET_KNOWLEDGE_FILE" >/dev/null 2>&1; then
        atomic_write "$FLEET_KNOWLEDGE_FILE" '{
  "version": 1,
  "generated_at": "",
  "patterns": [],
  "metrics": {
    "total_patterns": 0,
    "cross_repo_patterns": 0,
    "repos_scanned": 0,
    "last_mine_at": "",
    "total_injections": 0,
    "total_transfers": 0
  }
}'
    fi
}

# km_signature <text>
# Produce a stable cross-repo signature for a pattern/error string by
# normalizing (strip ANSI, lowercase, mask digits, collapse whitespace) then
# hashing. Mirrors the dedup/signature approach in sw-memory.sh so semantically
# identical failures from different repos collapse to the same signature.
km_signature() {
    local text="${1:-}"
    local norm
    norm=$(printf '%s' "$text" \
        | sed -e $'s/\033\\[[0-9;]*m//g' \
        | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/[0-9][0-9]*/N/g' \
              -e 's/[[:space:]][[:space:]]*/ /g' \
              -e 's/^ *//' -e 's/ *$//')
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$norm" | shasum -a 256 | cut -c1-12
    else
        printf '%s' "$norm" | sha256sum | cut -c1-12
    fi
}

# km_confidence <repo_count> <total_occurrences>
# Fleet-wide confidence (0-100). Cross-repo recurrence is the dominant signal:
# a pattern seen in many repos is far more trustworthy than one seen many times
# in a single repo. Mirrors discovery_score_confidence's bounded-additive style.
km_confidence() {
    local repo_count="${1:-1}"
    local total_occ="${2:-1}"
    local confidence=0

    # Cross-repo breadth (max 75 points: each additional repo adds 25)
    local repo_score=$((repo_count * 25))
    [[ "$repo_score" -gt 75 ]] && repo_score=75
    confidence=$((confidence + repo_score))

    # Occurrence depth (max 25 points: capped at 10 occurrences)
    local occ=$total_occ
    [[ "$occ" -gt 10 ]] && occ=10
    local occ_score=$((occ * 25 / 10))
    confidence=$((confidence + occ_score))

    [[ "$confidence" -gt 100 ]] && confidence=100
    echo "$confidence"
}

# Iterate over per-repo memory directories, printing the absolute path of each.
# A "repo" dir is any subdirectory of MEMORY_ROOT containing memory JSON.
km_iter_repos() {
    [[ -d "$MEMORY_ROOT" ]] || return 0
    local d
    for d in "$MEMORY_ROOT"/*/; do
        [[ -d "$d" ]] || continue
        if [[ -f "${d}failures.json" || -f "${d}knowledge.json" ]]; then
            echo "${d%/}"
        fi
    done
}

# jq filter that extracts normalized mining entries from a failures.json file.
# Emits one compact JSON object per line.
_km_extract_failures() {
    local file="$1" repo="$2" repo_name="$3"
    jq -c --arg repo "$repo" --arg rn "$repo_name" '
        .failures[]?
        | select((.pattern // "") != "")
        | {
            repo: $repo,
            repo_name: $rn,
            kind: "failure",
            category: (.category // "failure"),
            summary: (.pattern),
            fix: (.fix // ""),
            tags: ([.stage, .category] | map(select(. != null and . != ""))),
            occurrences: (.seen_count // 1),
            last_seen: (.last_seen // "")
          }
    ' "$file" 2>/dev/null || true
}

# jq filter that extracts normalized mining entries from a knowledge.json file.
_km_extract_knowledge() {
    local file="$1" repo="$2" repo_name="$3"
    jq -c --arg repo "$repo" --arg rn "$repo_name" '
        .entries[]?
        | select((.error_signature // "") != "")
        | {
            repo: $repo,
            repo_name: $rn,
            kind: (.kind // "failure"),
            category: (.error_type // "unknown"),
            summary: (.error_signature),
            fix: (.fix_strategy // ""),
            tags: (.tags // []),
            occurrences: (.metrics.occurrences // 1),
            last_seen: (.metrics.last_used_at // "")
          }
    ' "$file" 2>/dev/null || true
}

# Resolve a friendly repo name from a repo memory dir (patterns.json .repo),
# falling back to the directory basename (the repo hash).
_km_repo_name() {
    local repo_dir="$1" name=""
    if [[ -f "${repo_dir}/patterns.json" ]]; then
        name=$(jq -r '.repo // ""' "${repo_dir}/patterns.json" 2>/dev/null || echo "")
    fi
    [[ -z "$name" || "$name" == "null" ]] && name="$(basename "$repo_dir")"
    echo "$name"
}

# ─── cmd_mine ─────────────────────────────────────────────────────────────
# Mine all per-repo memory, consolidate by cross-repo signature, score
# confidence, and write fleet-knowledge.json atomically.
cmd_mine() {
    ensure_knowledge_file

    info "Mining fleet-wide patterns from ${MEMORY_ROOT}..."

    local raw_entries sigged_entries
    raw_entries=$(mktemp "${TMPDIR:-/tmp}/sw-km-raw.XXXXXX")
    sigged_entries=$(mktemp "${TMPDIR:-/tmp}/sw-km-sig.XXXXXX")

    local repos_scanned=0 repo_dir repo_hash repo_name
    while IFS= read -r repo_dir; do
        [[ -z "$repo_dir" ]] && continue
        repo_hash="$(basename "$repo_dir")"
        repo_name="$(_km_repo_name "$repo_dir")"
        repos_scanned=$((repos_scanned + 1))
        [[ -f "${repo_dir}/failures.json" ]]  && _km_extract_failures  "${repo_dir}/failures.json"  "$repo_hash" "$repo_name" >> "$raw_entries"
        [[ -f "${repo_dir}/knowledge.json" ]] && _km_extract_knowledge "${repo_dir}/knowledge.json" "$repo_hash" "$repo_name" >> "$raw_entries"
    done < <(km_iter_repos)

    # Attach a stable signature to each raw entry (normalization + hash in bash
    # so semantically identical failures across repos share a signature).
    local line summary sig
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        summary=$(jq -r '.summary' <<< "$line" 2>/dev/null || echo "")
        [[ -z "$summary" ]] && continue
        sig=$(km_signature "$summary")
        jq -c --arg sig "$sig" '. + {signature: $sig}' <<< "$line" 2>/dev/null || true
    done < "$raw_entries" > "$sigged_entries"

    # Consolidate entries by signature across repos.
    local patterns
    patterns=$(jq -s --arg ts "$(now_iso)" '
        group_by(.signature)
        | map({
            signature: .[0].signature,
            kind: .[0].kind,
            category: ((map(.category) | map(select(. != null and . != "")) | .[0]) // "uncategorized"),
            summary: .[0].summary,
            fix: ((map(.fix) | map(select(. != null and . != "")) | .[0]) // ""),
            tags: ([.[].tags[]?] | map(select(. != null and . != "")) | unique),
            repos: ([.[].repo_name] | unique),
            repo_count: ([.[].repo] | unique | length),
            total_occurrences: ([.[].occurrences] | map(. // 1) | add),
            last_seen: ([.[].last_seen] | map(select(. != null and . != "")) | max // ""),
            mined_at: $ts
          })
    ' "$sigged_entries" 2>/dev/null || echo "[]")
    [[ -z "$patterns" ]] && patterns="[]"

    # Score confidence per pattern (cross-repo breadth dominates) and sort.
    local count i repo_count total_occ conf scored="[]"
    count=$(jq 'length' <<< "$patterns" 2>/dev/null || echo "0")
    i=0
    while [[ "$i" -lt "$count" ]]; do
        repo_count=$(jq -r ".[$i].repo_count // 1" <<< "$patterns")
        total_occ=$(jq -r ".[$i].total_occurrences // 1" <<< "$patterns")
        conf=$(km_confidence "$repo_count" "$total_occ")
        scored=$(jq --argjson e "$(jq ".[$i]" <<< "$patterns")" --argjson c "$conf" \
            '. + [$e + {confidence: $c}]' <<< "$scored")
        i=$((i + 1))
    done
    scored=$(jq 'sort_by(-.confidence, -.repo_count, -.total_occurrences)' <<< "$scored")

    # Preserve cumulative injection/transfer counters across mine runs.
    local prev_inj prev_xfer
    prev_inj=$(jq -r '.metrics.total_injections // 0' "$FLEET_KNOWLEDGE_FILE" 2>/dev/null || echo "0")
    prev_xfer=$(jq -r '.metrics.total_transfers // 0' "$FLEET_KNOWLEDGE_FILE" 2>/dev/null || echo "0")

    local total_patterns cross_repo
    total_patterns=$(jq 'length' <<< "$scored")
    cross_repo=$(jq --argjson t "$KM_CROSS_REPO_THRESHOLD" '[.[] | select(.repo_count >= $t)] | length' <<< "$scored")

    local doc
    doc=$(jq -n \
        --argjson patterns "$scored" \
        --arg ts "$(now_iso)" \
        --argjson total "$total_patterns" \
        --argjson cross "$cross_repo" \
        --argjson scanned "$repos_scanned" \
        --argjson inj "$prev_inj" \
        --argjson xfer "$prev_xfer" \
        '{
            version: 1,
            generated_at: $ts,
            patterns: $patterns,
            metrics: {
                total_patterns: $total,
                cross_repo_patterns: $cross,
                repos_scanned: $scanned,
                last_mine_at: $ts,
                total_injections: $inj,
                total_transfers: $xfer
            }
        }')

    atomic_write "$FLEET_KNOWLEDGE_FILE" "$doc"
    rm -f "$raw_entries" "$sigged_entries"

    emit_event "knowledge.mined" \
        "repos=$repos_scanned" \
        "patterns=$total_patterns" \
        "cross_repo=$cross_repo"

    success "Mined $total_patterns patterns ($cross_repo cross-repo) from $repos_scanned repos"
    info "Fleet knowledge: $FLEET_KNOWLEDGE_FILE"
}

# ─── cmd_transfer ───────────────────────────────────────────────────────────
# Promote fleet-wide (cross-repo) patterns into global.json additively,
# deduped by signature and capped.
cmd_transfer() {
    ensure_knowledge_file

    if [[ ! -f "$GLOBAL_FILE" ]]; then
        atomic_write "$GLOBAL_FILE" '{"common_patterns":[],"cross_repo_learnings":[]}'
    fi
    # Repair a malformed/empty global.json.
    if ! jq -e '.common_patterns and .cross_repo_learnings' "$GLOBAL_FILE" >/dev/null 2>&1; then
        atomic_write "$GLOBAL_FILE" '{"common_patterns":[],"cross_repo_learnings":[]}'
    fi

    # Candidates: cross-repo patterns, highest confidence first, capped.
    local candidates
    candidates=$(jq --argjson t "$KM_CROSS_REPO_THRESHOLD" --argjson cap "$KM_TRANSFER_CAP" \
        '[.patterns[] | select(.repo_count >= $t)]
         | sort_by(-.confidence, -.repo_count)
         | .[:$cap]' "$FLEET_KNOWLEDGE_FILE" 2>/dev/null || echo "[]")
    [[ -z "$candidates" ]] && candidates="[]"

    local cand_count
    cand_count=$(jq 'length' <<< "$candidates")
    if [[ "$cand_count" -eq 0 ]]; then
        warn "No cross-repo patterns (>= ${KM_CROSS_REPO_THRESHOLD} repos) to transfer. Run 'knowledge mine' first."
        return 0
    fi

    # Merge additively into global.json, deduped by signature.
    local merged
    merged=$(jq \
        --argjson cands "$candidates" \
        --arg ts "$(now_iso)" '
        . as $g
        | ($g.cross_repo_learnings // []) as $existing
        | ([$existing[].signature // empty] | unique) as $seen
        | ($cands | map(select((.signature as $s | $seen | index($s)) | not)
            | {
                signature: .signature,
                pattern: .summary,
                fix: .fix,
                category: .category,
                repos: .repos,
                repo_count: .repo_count,
                confidence: .confidence,
                source: "fleet-mining",
                transferred_at: $ts
              })) as $new
        | .cross_repo_learnings = ($existing + $new)
        | .common_patterns = ((.common_patterns // []) + ($new | map({pattern: .pattern, signature: .signature, source: "fleet-mining", promoted_at: $ts})))
        ' "$GLOBAL_FILE" 2>/dev/null || echo "")

    if [[ -z "$merged" ]]; then
        error "Transfer failed: could not merge into global.json"
        return 1
    fi

    local before after added
    before=$(jq '.cross_repo_learnings | length' "$GLOBAL_FILE" 2>/dev/null || echo "0")
    atomic_write "$GLOBAL_FILE" "$merged"
    after=$(jq '.cross_repo_learnings | length' "$GLOBAL_FILE" 2>/dev/null || echo "0")
    added=$((after - before))

    # Bump transfer counter on the fleet knowledge file.
    local bumped
    bumped=$(jq --argjson n "$added" '.metrics.total_transfers = ((.metrics.total_transfers // 0) + $n)' \
        "$FLEET_KNOWLEDGE_FILE" 2>/dev/null || echo "")
    [[ -n "$bumped" ]] && atomic_write "$FLEET_KNOWLEDGE_FILE" "$bumped"

    emit_event "knowledge.transferred" "added=$added" "candidates=$cand_count"
    success "Transferred $added new fleet-wide pattern(s) into global.json"
}

# ─── cmd_inject ─────────────────────────────────────────────────────────────
# Emit a ranked, injectable context block of fleet-wide patterns relevant to a
# task type. Ranking blends tag Jaccard overlap with task tokens + confidence.
cmd_inject() {
    local task_type="${1:-build}"
    local max_results="${2:-5}"
    ensure_knowledge_file

    local total
    total=$(jq '.patterns | length' "$FLEET_KNOWLEDGE_FILE" 2>/dev/null || echo "0")
    if [[ "$total" -eq 0 ]]; then
        echo "# No fleet-wide knowledge available yet. Run 'shipwright knowledge mine'."
        return 0
    fi

    # Tokenize the task type into lowercase words for Jaccard tag overlap.
    local task_tokens
    task_tokens=$(printf '%s' "$task_type" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '\n' | jq -R . | jq -sc 'map(select(. != ""))')

    # Rank: jaccard(tags, task_tokens) drives relevance; confidence breaks ties.
    local ranked
    ranked=$(jq --argjson tokens "$task_tokens" --argjson n "$max_results" '
        [.patterns[]
         | . as $p
         | ($p.tags // [] | map(ascii_downcase)) as $tags
         | (($tags + $tokens) | unique | length) as $union
         | (if $union == 0 then 0
            else ([$tags[] | select(. as $t | $tokens | index($t))] | length) / $union end) as $jacc
         | $p + {relevance: $jacc}]
        | sort_by(-.relevance, -.confidence, -.repo_count)
        | .[:$n]
    ' "$FLEET_KNOWLEDGE_FILE" 2>/dev/null || echo "[]")
    [[ -z "$ranked" ]] && ranked="[]"

    echo "# Fleet-Wide Knowledge Context"
    echo "# Injected at: $(now_iso)"
    echo "# Task type: ${task_type}"
    echo ""
    echo "## Cross-Repo Patterns (mined across the fleet)"

    local emitted
    emitted=$(jq -r '
        .[] | "- [\(.category)] \(.summary | gsub("\\[[0-9;]*m";"") | .[0:160])"
            + " (repos: \(.repo_count), confidence: \(.confidence))"
            + (if (.fix // "") != "" then "\n    fix: " + (.fix | .[0:200]) else "" end)
    ' <<< "$ranked" 2>/dev/null || true)

    if [[ -z "$emitted" ]]; then
        echo "- No relevant fleet-wide patterns for task type '${task_type}'."
    else
        echo "$emitted"
    fi

    # Bump injection counter (best-effort, atomic).
    local bumped
    bumped=$(jq '.metrics.total_injections = ((.metrics.total_injections // 0) + 1)' \
        "$FLEET_KNOWLEDGE_FILE" 2>/dev/null || echo "")
    [[ -n "$bumped" ]] && atomic_write "$FLEET_KNOWLEDGE_FILE" "$bumped"
}

# ─── cmd_search ─────────────────────────────────────────────────────────────
# Search mined patterns by free-text query (matches summary/fix/category/tags).
cmd_search() {
    local query="${1:-}"
    if [[ -z "$query" ]]; then
        error "Usage: shipwright knowledge search <query>"
        return 1
    fi
    ensure_knowledge_file

    local lc_query
    lc_query=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')

    local matches
    matches=$(jq --arg q "$lc_query" '
        [.patterns[]
         | select(
             ((.summary // "") | ascii_downcase | contains($q)) or
             ((.fix // "") | ascii_downcase | contains($q)) or
             ((.category // "") | ascii_downcase | contains($q)) or
             ((.tags // []) | map(ascii_downcase) | any(contains($q)))
           )]
        | sort_by(-.confidence, -.repo_count)
    ' "$FLEET_KNOWLEDGE_FILE" 2>/dev/null || echo "[]")
    [[ -z "$matches" ]] && matches="[]"

    local n
    n=$(jq 'length' <<< "$matches")
    info "Found $n pattern(s) matching '$query'"
    [[ "$n" -eq 0 ]] && return 0

    jq -r '.[] | "  • [\(.category)] (repos: \(.repo_count), conf: \(.confidence)) \(.summary | gsub("\\[[0-9;]*m";"") | .[0:120])"' <<< "$matches"
}

# ─── cmd_show ─────────────────────────────────────────────────────────────
# Show the top mined patterns (or full JSON with --json).
cmd_show() {
    ensure_knowledge_file
    if [[ "${1:-}" == "--json" ]]; then
        cat "$FLEET_KNOWLEDGE_FILE"
        return 0
    fi

    local total cross repos
    total=$(jq -r '.metrics.total_patterns // 0' "$FLEET_KNOWLEDGE_FILE")
    cross=$(jq -r '.metrics.cross_repo_patterns // 0' "$FLEET_KNOWLEDGE_FILE")
    repos=$(jq -r '.metrics.repos_scanned // 0' "$FLEET_KNOWLEDGE_FILE")

    echo ""
    info "Fleet Knowledge — $total patterns, $cross cross-repo, $repos repos scanned"
    echo ""
    if [[ "$total" -eq 0 ]]; then
        echo "  (empty — run 'shipwright knowledge mine')"
        echo ""
        return 0
    fi
    jq -r '.patterns[:20][] | "  • [\(.category)] (repos: \(.repo_count), occ: \(.total_occurrences), conf: \(.confidence)) \(.summary | gsub("\\[[0-9;]*m";"") | .[0:100])"' \
        "$FLEET_KNOWLEDGE_FILE" 2>/dev/null || true
    echo ""
}

# ─── cmd_report ─────────────────────────────────────────────────────────────
# Summary report of fleet knowledge health and transfer/injection activity.
cmd_report() {
    ensure_knowledge_file

    local total cross repos last_mine inj xfer
    total=$(jq -r '.metrics.total_patterns // 0' "$FLEET_KNOWLEDGE_FILE")
    cross=$(jq -r '.metrics.cross_repo_patterns // 0' "$FLEET_KNOWLEDGE_FILE")
    repos=$(jq -r '.metrics.repos_scanned // 0' "$FLEET_KNOWLEDGE_FILE")
    last_mine=$(jq -r '.metrics.last_mine_at // "never"' "$FLEET_KNOWLEDGE_FILE")
    inj=$(jq -r '.metrics.total_injections // 0' "$FLEET_KNOWLEDGE_FILE")
    xfer=$(jq -r '.metrics.total_transfers // 0' "$FLEET_KNOWLEDGE_FILE")

    echo ""
    echo "  Fleet-Wide Knowledge Report"
    echo "  ═══════════════════════════════════════════"
    echo "  Total patterns mined:     $total"
    echo "  Cross-repo patterns:      $cross  (>= ${KM_CROSS_REPO_THRESHOLD} repos)"
    echo "  Repos scanned:            $repos"
    echo "  Last mined:               $last_mine"
    echo "  Patterns transferred:     $xfer"
    echo "  Context injections:       $inj"
    echo ""

    if [[ "$cross" -gt 0 ]]; then
        echo "  Top cross-repo patterns:"
        jq -r --argjson t "$KM_CROSS_REPO_THRESHOLD" \
            '[.patterns[] | select(.repo_count >= $t)] | sort_by(-.confidence) | .[:5][]
             | "    • [\(.category)] conf \(.confidence), \(.repo_count) repos: \(.summary | gsub("\\[[0-9;]*m";"") | .[0:80])"' \
            "$FLEET_KNOWLEDGE_FILE" 2>/dev/null || true
        echo ""
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# SUCCESS-PATTERN MINING & RECOMMENDATION (issue #668)
# ════════════════════════════════════════════════════════════════════════════

# Seed an empty schema-v1 fleet-patterns.json if missing or unparseable, or if
# the on-disk version is not the version we understand (forward-only: unknown
# versions are reseeded rather than transformed in place).
fp_ensure_file() {
    mkdir -p "$(dirname "$FLEET_PATTERNS_FILE")"
    if [[ ! -f "$FLEET_PATTERNS_FILE" ]] \
       || ! jq -e '.patterns and .metrics and (.version == 1)' "$FLEET_PATTERNS_FILE" >/dev/null 2>&1; then
        atomic_write "$FLEET_PATTERNS_FILE" '{
  "version": 1,
  "generated_at": "",
  "patterns": [],
  "metrics": {
    "total_patterns": 0,
    "repos_scanned": 0,
    "events_scanned": 0,
    "total_recommendations": 0,
    "total_reuses": 0,
    "reuse_rate": 0,
    "avg_success_rate": 0,
    "last_mine_at": ""
  }
}'
    fi
}

# fp_complexity_bucket <complexity-int> — coarse bucket used in the grouping
# signature so semantically similar issues consolidate even when their numeric
# complexity differs slightly.
fp_complexity_bucket() {
    local c="${1:-0}"
    [[ "$c" =~ ^[0-9]+$ ]] || c=0
    if   [[ "$c" -lt 4 ]]; then echo "low"
    elif [[ "$c" -le 7 ]]; then echo "medium"
    else echo "high"
    fi
}

# fp_tokenize <text> — lowercase, split on non-alphanumeric, drop empties,
# dedupe. Emits a compact JSON array. Mirrors the recommend-time tokenizer so
# mine and recommend agree on token identity.
fp_tokenize() {
    printf '%s' "${1:-}" \
        | jq -Rc 'ascii_downcase | gsub("[^a-z0-9]+";" ") | split(" ") | map(select(length>0)) | unique'
}

# ─── cmd_mine_success ───────────────────────────────────────────────────────
# SOLE WRITER of fleet-patterns.json. Reads events.jsonl tolerantly (torn lines
# are dropped, never abort), selects successful pipeline.completed events,
# consolidates by (template | complexity_bucket | goal_tokens) signature, and
# writes aggregate success metadata. Always exits 0.
cmd_mine_success() {
    fp_ensure_file

    info "Mining successful pipeline patterns from ${EVENTS_FILE}..."

    local projected
    projected=$(mktemp "${TMPDIR:-/tmp}/sw-fp-proj.XXXXXX")

    # Tolerant, line-by-line projection. A malformed line yields a jq error that
    # is swallowed (|| true), so a single torn write never aborts the mine.
    if [[ -f "$EVENTS_FILE" ]]; then
        local line
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf '%s\n' "$line" | jq -c '
                select(.type == "pipeline.completed")
                | {
                    result: (.result // "unknown"),
                    template: (.template // "standard"),
                    complexity: (((.complexity // 0) | tonumber?) // 0),
                    iterations: (((.iterations // 1) | tonumber?) // 1),
                    cost: (((.total_cost // 0) | tonumber?) // 0),
                    repo: (.repo // "local"),
                    ts: (.ts // "")
                  }
                + { tokens: ((.goal // "") | ascii_downcase | gsub("[^a-z0-9]+";" ") | split(" ") | map(select(length>0)) | unique) }
                | . + { bucket: (if .complexity < 4 then "low" elif .complexity <= 7 then "medium" else "high" end) }
                | . + { sigkey: "\(.template)|\(.bucket)|\(.tokens | join(" "))" }
            ' 2>/dev/null || true
        done < "$EVENTS_FILE" > "$projected"
    fi

    local events_scanned
    events_scanned=$(grep -c '' "$projected" 2>/dev/null || true)
    events_scanned=${events_scanned:-0}

    # Consolidate by signature. A group is kept only if it has >=1 success;
    # success_rate is computed over all runs (success+failure) sharing the
    # signature, while averages use only the successful runs.
    local grouped
    grouped=$(jq -s '
        group_by(.sigkey)
        | map(
            . as $g
            | ($g | map(select(.result == "success"))) as $s
            | ($s | length) as $sc
            | select($sc > 0)
            | {
                sigkey: $g[0].sigkey,
                template: $g[0].template,
                complexity: (($s | map(.complexity) | add) / $sc | floor),
                goal_tokens: $g[0].tokens,
                repos: ([$s[].repo] | unique),
                repo_count: ([$s[].repo] | unique | length),
                applied_count: $sc,
                total_runs: ($g | length),
                success_rate: (($sc * 100 / ($g | length)) | floor),
                avg_iterations: (($s | map(.iterations) | add) / $sc | floor),
                avg_cost_usd: ((($s | map(.cost) | add) / $sc * 100 | round) / 100),
                last_seen: ([$s[].ts] | max // "")
              }
          )
    ' "$projected" 2>/dev/null || echo "[]")
    [[ -z "$grouped" ]] && grouped="[]"

    # Recount reuse events per signature (reconcile, never increment — see ADR).
    # Build a flat list of recommended signatures first.
    local rec_file
    rec_file=$(mktemp "${TMPDIR:-/tmp}/sw-fp-rec.XXXXXX")
    if [[ -f "$EVENTS_FILE" ]]; then
        grep '"type":"knowledge.pattern_recommended"' "$EVENTS_FILE" 2>/dev/null \
            | jq -r '.signature // empty' 2>/dev/null > "$rec_file" || true
    fi
    local total_recommendations
    total_recommendations=$(grep -c '' "$rec_file" 2>/dev/null || true)
    total_recommendations=${total_recommendations:-0}

    # Attach a stable signature + reconciled reuse count to each pattern.
    local count i sigkey sig reuses scored="[]" total_reuses=0
    count=$(jq 'length' <<< "$grouped" 2>/dev/null || echo 0)
    i=0
    while [[ "$i" -lt "$count" ]]; do
        sigkey=$(jq -r ".[$i].sigkey" <<< "$grouped")
        sig=$(km_signature "$sigkey")
        reuses=$(grep -cxF "$sig" "$rec_file" 2>/dev/null || true)
        reuses=${reuses:-0}
        total_reuses=$((total_reuses + reuses))
        scored=$(jq \
            --argjson e "$(jq ".[$i]" <<< "$grouped")" \
            --arg sig "$sig" \
            --argjson reuses "$reuses" \
            --arg mined "$(now_iso)" \
            '. + [($e | del(.sigkey, .total_runs)) + {signature: $sig, total_reuses: $reuses, mined_at: $mined}]' \
            <<< "$scored")
        i=$((i + 1))
    done
    scored=$(jq 'sort_by(-.success_rate, -.applied_count, -.repo_count)' <<< "$scored")

    local total_patterns repos_scanned avg_success reuse_rate
    total_patterns=$(jq 'length' <<< "$scored")
    repos_scanned=$(jq -s '[.[] | select(.result == "success") | .repo] | unique | length' "$projected" 2>/dev/null || echo 0)
    avg_success=$(jq 'if length == 0 then 0 else ([.[].success_rate] | add / length | floor) end' <<< "$scored")
    if [[ "$total_recommendations" -gt 0 ]]; then
        reuse_rate=$(( total_reuses * 100 / total_recommendations ))
    else
        reuse_rate=0
    fi

    local doc
    doc=$(jq -n \
        --argjson patterns "$scored" \
        --arg ts "$(now_iso)" \
        --argjson total "$total_patterns" \
        --argjson repos "$repos_scanned" \
        --argjson scanned "$events_scanned" \
        --argjson recs "$total_recommendations" \
        --argjson reuses "$total_reuses" \
        --argjson rate "$reuse_rate" \
        --argjson avg "$avg_success" \
        '{
            version: 1,
            generated_at: $ts,
            patterns: $patterns,
            metrics: {
                total_patterns: $total,
                repos_scanned: $repos,
                events_scanned: $scanned,
                total_recommendations: $recs,
                total_reuses: $reuses,
                reuse_rate: $rate,
                avg_success_rate: $avg,
                last_mine_at: $ts
            }
        }')

    atomic_write "$FLEET_PATTERNS_FILE" "$doc"
    rm -f "$projected" "$rec_file"

    emit_event "knowledge.success_mined" \
        "patterns=$total_patterns" \
        "events=$events_scanned" \
        "repos=$repos_scanned"

    success "Mined $total_patterns success pattern(s) from $events_scanned completed event(s)"
    info "Fleet patterns: $FLEET_PATTERNS_FILE"
    return 0
}

# ─── cmd_recommend ──────────────────────────────────────────────────────────
# PURE READ. Ranks success patterns against an issue (title + complexity) by a
# pinned, deterministic scoring formula and prints the qualifying matches.
# Emits nothing, writes nothing. Usage:
#   knowledge recommend [--json] "<title>" <complexity> [max]
cmd_recommend() {
    local as_json=false
    if [[ "${1:-}" == "--json" ]]; then as_json=true; shift; fi

    local title="${1:-}"
    local complexity="${2:-5}"
    local max="${3:-3}"
    [[ "$complexity" =~ ^[0-9]+$ ]] || complexity=5

    if [[ -z "$title" ]]; then
        error "Usage: shipwright knowledge recommend [--json] \"<title>\" <complexity> [max]"
        return 1
    fi
    fp_ensure_file

    local tokens
    tokens=$(fp_tokenize "$title")
    [[ -z "$tokens" ]] && tokens="[]"

    local ranked
    ranked=$(jq \
        --argjson tokens "$tokens" \
        --argjson ci "$complexity" \
        --argjson thr "$SW_FLEET_RECOMMEND_THRESHOLD" \
        --argjson minapp "$SW_FLEET_MIN_APPLIED" \
        --argjson minsr "$SW_FLEET_MIN_SUCCESS_RATE" \
        --argjson n "$max" '
        [.patterns[]
         | . as $p
         | ($p.goal_tokens // []) as $pt
         | (($tokens + $pt) | unique | length) as $union
         | ([$tokens[] | select(. as $x | $pt | index($x))] | length) as $inter
         | (if $union == 0 then 0 else ($inter / $union) end) as $overlap
         | ($ci - ($p.complexity // 0)) as $d
         | (if $d < 0 then -$d else $d end) as $ad
         | ([[ (1 - ($ad / 10)), 0] | max, 1] | min) as $cm
         | (([($p.repo_count // 1), 5] | min) / 5) as $rn
         | (100 * (0.5 * $overlap + 0.3 * $cm + 0.2 * $rn) + 0.5 | floor) as $score
         | $p + {score: $score, match_overlap: (($overlap * 100) | floor)}]
        | map(select(.score >= $thr and (.success_rate // 0) >= $minsr and (.applied_count // 0) >= $minapp))
        | sort_by(-.score, -.success_rate, -.repo_count)
        | .[:$n]
    ' "$FLEET_PATTERNS_FILE" 2>/dev/null || echo "[]")
    [[ -z "$ranked" ]] && ranked="[]"

    if [[ "$as_json" == "true" ]]; then
        echo "$ranked"
        return 0
    fi

    local n
    n=$(jq 'length' <<< "$ranked" 2>/dev/null || echo 0)
    echo "# Fleet Pattern Recommendation"
    echo "# Issue: ${title}"
    echo "# Complexity: ${complexity}  ·  Threshold: ${SW_FLEET_RECOMMEND_THRESHOLD}"
    echo ""
    if [[ "$n" -eq 0 ]]; then
        echo "NO_RECOMMENDATION — no success pattern cleared the gate (score >= ${SW_FLEET_RECOMMEND_THRESHOLD}, success_rate >= ${SW_FLEET_MIN_SUCCESS_RATE}%, applied >= ${SW_FLEET_MIN_APPLIED})."
        return 0
    fi
    jq -r '.[]
        | "- template: \(.template) (score \(.score), success_rate \(.success_rate)%, applied \(.applied_count)x across \(.repo_count) repo(s))"
        + "\n    avg_iterations: \(.avg_iterations)  ·  avg_cost: $\(.avg_cost_usd)  ·  signature: \(.signature)"' \
        <<< "$ranked" 2>/dev/null || true
}

# ─── cmd_patterns_report ─────────────────────────────────────────────────────
# Health/activity report for the success-pattern library, including the
# event-schema drift signal (events_scanned vs total_patterns).
cmd_patterns_report() {
    fp_ensure_file

    local total repos scanned recs reuses rate avg last_mine
    total=$(jq -r '.metrics.total_patterns // 0' "$FLEET_PATTERNS_FILE")
    repos=$(jq -r '.metrics.repos_scanned // 0' "$FLEET_PATTERNS_FILE")
    scanned=$(jq -r '.metrics.events_scanned // 0' "$FLEET_PATTERNS_FILE")
    recs=$(jq -r '.metrics.total_recommendations // 0' "$FLEET_PATTERNS_FILE")
    reuses=$(jq -r '.metrics.total_reuses // 0' "$FLEET_PATTERNS_FILE")
    rate=$(jq -r '.metrics.reuse_rate // 0' "$FLEET_PATTERNS_FILE")
    avg=$(jq -r '.metrics.avg_success_rate // 0' "$FLEET_PATTERNS_FILE")
    last_mine=$(jq -r '.metrics.last_mine_at // "never"' "$FLEET_PATTERNS_FILE")

    echo ""
    echo "  Fleet Success-Pattern Report"
    echo "  ═══════════════════════════════════════════"
    echo "  Success patterns mined:   $total"
    echo "  Repos represented:        $repos"
    echo "  Completed events scanned: $scanned"
    echo "  Avg success rate:         ${avg}%"
    echo "  Recommendations made:     $recs"
    echo "  Pattern reuses:           $reuses"
    echo "  Reuse rate:               ${rate}%"
    echo "  Last mined:               $last_mine"
    echo ""

    # Drift alarm: events were scanned but consolidated into zero patterns —
    # the most likely cause is an event-schema rename (template/complexity/etc).
    if [[ "$scanned" -gt 0 && "$total" -eq 0 ]]; then
        warn "Drift signal: scanned $scanned completed event(s) but mined 0 patterns — check pipeline.completed event fields (template/complexity/result)."
        echo ""
    fi

    if [[ "$total" -gt 0 ]]; then
        echo "  Top success patterns:"
        jq -r '.patterns | sort_by(-.success_rate, -.applied_count) | .[:5][]
            | "    • \(.template) — \(.success_rate)% over \(.applied_count) run(s), \(.repo_count) repo(s), ~\(.avg_iterations) iter, $\(.avg_cost_usd) [\(.goal_tokens | join(" "))]"' \
            "$FLEET_PATTERNS_FILE" 2>/dev/null || true
        echo ""
    fi
}

# ─── Help ─────────────────────────────────────────────────────────────────
show_help() {
    cat <<'EOF'
shipwright knowledge — Fleet-Wide Pattern Mining & Knowledge Transfer

USAGE:
  shipwright knowledge <command> [args]

COMMANDS:
  mine                      Mine all per-repo memory, consolidate recurring
                            FAILURE patterns by cross-repo signature, score
                            confidence, and write fleet-knowledge.json
  mine-success              Mine SUCCESSFUL pipeline configurations from the
                            event log (template, iterations, cost, success rate)
                            into fleet-patterns.json
  recommend [--json] "<title>" <complexity> [max]
                            Recommend a proven pipeline approach for a new issue
                            by similarity + complexity + cross-repo breadth
  patterns-report           Success-pattern library health & reuse report
  transfer                  Promote cross-repo patterns into global.json
                            (additive, deduped, capped)
  inject <task_type> [n]    Emit ranked injectable context for a pipeline stage
  search <query>            Search mined patterns by free text
  show [--json]             Show top mined patterns (or raw JSON)
  report                    Fleet knowledge health & activity report
  help                      Show this help

ALIASES:
  'mine' is also reachable directly as 'shipwright mine'

ENVIRONMENT:
  KM_CROSS_REPO_THRESHOLD       Min repos for a pattern to be "fleet-wide" (default 2)
  KM_TRANSFER_CAP               Max patterns promoted per transfer (default 50)
  SW_FLEET_RECOMMEND_THRESHOLD  Min score (0-100) to recommend a pattern (default 60)
  SW_FLEET_MIN_APPLIED          Min successful applications to recommend (default 2)
  SW_FLEET_MIN_SUCCESS_RATE     Min success rate %% to recommend (default 50)

STORAGE:
  ~/.shipwright/memory/fleet-knowledge.json   Consolidated fleet FAILURE knowledge
  ~/.shipwright/memory/global.json            Transfer target (common patterns)
  ~/.shipwright/fleet-patterns.json           Mined SUCCESS patterns (schema v1)
EOF
}

# ─── main ─────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
        mine)            cmd_mine "$@" ;;
        mine-success)    cmd_mine_success "$@" ;;
        recommend)       cmd_recommend "$@" ;;
        patterns-report) cmd_patterns_report "$@" ;;
        transfer)        cmd_transfer "$@" ;;
        inject)          cmd_inject "$@" ;;
        search)          cmd_search "$@" ;;
        show)            cmd_show "$@" ;;
        report)          cmd_report "$@" ;;
        help|-h|--help)  show_help ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
