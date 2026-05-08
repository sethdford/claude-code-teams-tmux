#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright fleet-patterns — Fleet-Wide Pattern Learning System          ║
# ║  Cross-repo knowledge sharing: extract, query, score, prune patterns     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"

# Output fallbacks (test envs)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
: "${CYAN:=}" "${BOLD:=}" "${RESET:=}" "${DIM:=}" "${GREEN:=}" "${RED:=}" "${YELLOW:=}"
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(now_iso)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# ─── Storage Paths ─────────────────────────────────────────────────────────
FLEET_DIR="${HOME}/.shipwright"
PATTERNS_FILE="${FLEET_PATTERNS_FILE:-${FLEET_DIR}/fleet-patterns.json}"
EVENTS_FILE="${FLEET_DIR}/events.jsonl"

# ─── Schema ────────────────────────────────────────────────────────────────
SCHEMA_VERSION="1"

# ─── Utilities ─────────────────────────────────────────────────────────────

_require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required for fleet-patterns"
        return 1
    fi
}

# Atomic write: jq -> tmp -> mv
_atomic_write() {
    local target="$1" content="$2"
    local tmp
    tmp="$(mktemp "${target}.XXXXXX")"
    printf '%s' "$content" > "$tmp"
    mv "$tmp" "$target"
}

_ensure_store() {
    mkdir -p "$FLEET_DIR"
    if [[ ! -f "$PATTERNS_FILE" ]]; then
        local init
        init=$(jq -n --arg ver "$SCHEMA_VERSION" --arg ts "$(now_iso)" '{
            schema_version: $ver,
            created_at: $ts,
            updated_at: $ts,
            patterns: []
        }')
        _atomic_write "$PATTERNS_FILE" "$init"
    fi
    # Migration check: future schema versions
    local v
    v=$(jq -r '.schema_version // "0"' "$PATTERNS_FILE" 2>/dev/null || echo "0")
    if [[ "$v" != "$SCHEMA_VERSION" ]]; then
        warn "Pattern store schema version $v != $SCHEMA_VERSION (migration not yet implemented)"
    fi
}

# Stable signature: sha256 of (tech_stack|issue_signature|error_signature)
_pattern_id() {
    local tech="$1" issue="$2" err="$3"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s|%s|%s' "$tech" "$issue" "$err" | sha256sum | cut -c1-16
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s|%s|%s' "$tech" "$issue" "$err" | shasum -a 256 | cut -c1-16
    else
        # Fallback: low-quality hash
        printf '%s|%s|%s' "$tech" "$issue" "$err" | cksum | awk '{print $1}'
    fi
}

# Tokenize text: lowercase, alphanumeric, drop short words
_tokens() {
    echo "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '\n' | awk 'length($0) >= 3'
}

# Token-overlap similarity (0-100). a, b are strings.
_similarity() {
    local a="${1:-}" b="${2:-}"
    if [[ -z "$a" || -z "$b" ]]; then echo 0; return; fi
    local tmp_a tmp_b
    tmp_a=$(mktemp); tmp_b=$(mktemp)
    _tokens "$a" | sort -u > "$tmp_a"
    _tokens "$b" | sort -u > "$tmp_b"
    local na nb common union
    na=$(wc -l < "$tmp_a" | tr -d ' ')
    nb=$(wc -l < "$tmp_b" | tr -d ' ')
    common=$(comm -12 "$tmp_a" "$tmp_b" | wc -l | tr -d ' ')
    rm -f "$tmp_a" "$tmp_b"
    if [[ "$na" -eq 0 && "$nb" -eq 0 ]]; then echo 0; return; fi
    union=$(( na + nb - common ))
    if [[ "$union" -le 0 ]]; then echo 0; return; fi
    awk -v c="$common" -v u="$union" 'BEGIN{ printf "%d", (c/u)*100 }'
}

# ─── Subcommand: extract ───────────────────────────────────────────────────
# Extract a pattern from a successful pipeline run.
# Args (flags): --tech-stack, --issue-signature, --error-signature,
#               --root-cause, --fix, --files, --repo, --cost, --iterations
cmd_extract() {
    _require_jq || return 1
    _ensure_store

    local tech="" issue="" err="" root="" fix="" files="" repo="" cost="0" iters="1" outcome="success"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tech-stack) tech="$2"; shift 2 ;;
            --issue-signature) issue="$2"; shift 2 ;;
            --error-signature) err="$2"; shift 2 ;;
            --root-cause) root="$2"; shift 2 ;;
            --fix) fix="$2"; shift 2 ;;
            --files) files="$2"; shift 2 ;;
            --repo) repo="$2"; shift 2 ;;
            --cost) cost="$2"; shift 2 ;;
            --iterations) iters="$2"; shift 2 ;;
            --outcome) outcome="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$tech" && -z "$issue" && -z "$err" ]]; then
        error "extract requires at least one of --tech-stack, --issue-signature, --error-signature"
        return 1
    fi

    local id
    id=$(_pattern_id "$tech" "$issue" "$err")
    local now
    now=$(now_iso)

    local current new
    current=$(cat "$PATTERNS_FILE")

    # Idempotent upsert: if id exists, increment uses; else insert.
    new=$(jq --arg id "$id" \
             --arg tech "$tech" \
             --arg issue "$issue" \
             --arg err "$err" \
             --arg root "$root" \
             --arg fix "$fix" \
             --arg files "$files" \
             --arg repo "$repo" \
             --argjson cost "${cost:-0}" \
             --argjson iters "${iters:-1}" \
             --arg outcome "$outcome" \
             --arg now "$now" '
        .updated_at = $now |
        (.patterns | map(.id) | index($id)) as $i |
        if $i == null then
            .patterns += [{
                id: $id,
                tech_stack: $tech,
                issue_signature: $issue,
                error_signature: $err,
                root_cause: $root,
                fix: $fix,
                files: ($files | split(",") | map(select(length > 0))),
                source_repos: (if $repo == "" then [] else [$repo] end),
                created_at: $now,
                updated_at: $now,
                last_used_at: null,
                uses: 0,
                successes: (if $outcome == "success" then 1 else 0 end),
                failures: (if $outcome == "success" then 0 else 1 end),
                avg_cost_usd: $cost,
                avg_iterations: $iters,
                effectiveness: (if $outcome == "success" then 1.0 else 0.0 end)
            }]
        else
            .patterns[$i].updated_at = $now |
            .patterns[$i].source_repos = (.patterns[$i].source_repos + (if $repo == "" then [] else [$repo] end) | unique) |
            .patterns[$i].successes += (if $outcome == "success" then 1 else 0 end) |
            .patterns[$i].failures += (if $outcome == "success" then 0 else 1 end) |
            (.patterns[$i].successes + .patterns[$i].failures) as $tot |
            .patterns[$i].effectiveness = (if $tot > 0 then (.patterns[$i].successes / $tot) else 0 end) |
            .patterns[$i].avg_cost_usd = ((.patterns[$i].avg_cost_usd + $cost) / 2) |
            .patterns[$i].avg_iterations = ((.patterns[$i].avg_iterations + $iters) / 2) |
            (if $root != "" then .patterns[$i].root_cause = $root else . end) |
            (if $fix != "" then .patterns[$i].fix = $fix else . end)
        end
    ' <<<"$current")

    _atomic_write "$PATTERNS_FILE" "$new"
    emit_event "fleet_patterns_extract" "id=$id" "tech=$tech" "outcome=$outcome"
    echo "$id"
}

# ─── Subcommand: query ─────────────────────────────────────────────────────
# Find top-N patterns matching the given context. Composite score:
#   tech (40%) + issue (35%) + error (25%)
# Args: --tech-stack, --issue-signature, --error-signature, --top N, --threshold T, --json
cmd_query() {
    _require_jq || return 1
    _ensure_store

    local tech="" issue="" err="" top="3" threshold="0" want_json="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tech-stack) tech="$2"; shift 2 ;;
            --issue-signature) issue="$2"; shift 2 ;;
            --error-signature) err="$2"; shift 2 ;;
            --top) top="$2"; shift 2 ;;
            --threshold) threshold="$2"; shift 2 ;;
            --json) want_json="true"; shift ;;
            *) shift ;;
        esac
    done

    local count
    count=$(jq -r '.patterns | length' "$PATTERNS_FILE")
    if [[ "$count" -eq 0 ]]; then
        if [[ "$want_json" == "true" ]]; then echo '{"matches":[]}'
        else info "No patterns in store"; fi
        return 0
    fi

    local results="[]"
    local i=0
    while [[ "$i" -lt "$count" ]]; do
        local p_tech p_issue p_err id
        p_tech=$(jq -r ".patterns[$i].tech_stack // \"\"" "$PATTERNS_FILE")
        p_issue=$(jq -r ".patterns[$i].issue_signature // \"\"" "$PATTERNS_FILE")
        p_err=$(jq -r ".patterns[$i].error_signature // \"\"" "$PATTERNS_FILE")
        id=$(jq -r ".patterns[$i].id" "$PATTERNS_FILE")

        local s_tech s_issue s_err score
        s_tech=$(_similarity "$tech" "$p_tech")
        s_issue=$(_similarity "$issue" "$p_issue")
        s_err=$(_similarity "$err" "$p_err")
        score=$(awk -v t="$s_tech" -v i="$s_issue" -v e="$s_err" \
                'BEGIN{ printf "%d", (t*0.4)+(i*0.35)+(e*0.25) }')

        if [[ "$score" -ge "$threshold" ]]; then
            results=$(jq --arg id "$id" --argjson score "$score" \
                '. + [{id:$id, score:$score}]' <<<"$results")
        fi
        i=$((i+1))
    done

    # Sort, top N, join with full pattern records
    local matches
    matches=$(jq --slurpfile store "$PATTERNS_FILE" --argjson top "$top" '
        sort_by(-.score) | .[0:$top] |
        map(. as $r | ($store[0].patterns[] | select(.id == $r.id)) + {match_score: $r.score})
    ' <<<"$results")

    if [[ "$want_json" == "true" ]]; then
        jq -n --argjson m "$matches" '{matches:$m}'
    else
        local n
        n=$(jq 'length' <<<"$matches")
        if [[ "$n" -eq 0 ]]; then
            info "No matching patterns (threshold=$threshold)"
            return 0
        fi
        info "Top $n pattern matches:"
        jq -r '.[] | "  [\(.match_score)] \(.id) — tech:\(.tech_stack) issue:\(.issue_signature) eff:\(.effectiveness)"' <<<"$matches"
    fi
}

# ─── Subcommand: record-use ────────────────────────────────────────────────
# Record an outcome of using a pattern. Updates uses, successes/failures,
# effectiveness, and last_used_at.
# Args: --id PATTERN_ID --outcome success|failure [--cost N] [--iterations N]
cmd_record_use() {
    _require_jq || return 1
    _ensure_store

    local id="" outcome="" cost="0" iters="1"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id) id="$2"; shift 2 ;;
            --outcome) outcome="$2"; shift 2 ;;
            --cost) cost="$2"; shift 2 ;;
            --iterations) iters="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$id" || -z "$outcome" ]]; then
        error "record-use requires --id and --outcome"
        return 1
    fi
    if [[ "$outcome" != "success" && "$outcome" != "failure" ]]; then
        error "--outcome must be 'success' or 'failure'"
        return 1
    fi

    local now
    now=$(now_iso)

    local exists
    exists=$(jq --arg id "$id" '.patterns | map(.id) | index($id)' "$PATTERNS_FILE")
    if [[ "$exists" == "null" ]]; then
        error "Pattern id not found: $id"
        return 1
    fi

    local new
    new=$(jq --arg id "$id" \
             --arg outcome "$outcome" \
             --argjson cost "${cost:-0}" \
             --argjson iters "${iters:-1}" \
             --arg now "$now" '
        (.patterns | map(.id) | index($id)) as $i |
        .updated_at = $now |
        .patterns[$i].uses += 1 |
        .patterns[$i].last_used_at = $now |
        .patterns[$i].successes += (if $outcome == "success" then 1 else 0 end) |
        .patterns[$i].failures += (if $outcome == "success" then 0 else 1 end) |
        (.patterns[$i].successes + .patterns[$i].failures) as $tot |
        .patterns[$i].effectiveness = (if $tot > 0 then (.patterns[$i].successes / $tot) else 0 end) |
        .patterns[$i].avg_cost_usd = ((.patterns[$i].avg_cost_usd + $cost) / 2) |
        .patterns[$i].avg_iterations = ((.patterns[$i].avg_iterations + $iters) / 2)
    ' "$PATTERNS_FILE")

    _atomic_write "$PATTERNS_FILE" "$new"
    emit_event "fleet_patterns_use" "id=$id" "outcome=$outcome"
    success "Recorded $outcome for pattern $id"
}

# ─── Subcommand: prune ─────────────────────────────────────────────────────
# Evict patterns that are stale (older than --max-age-days) and ineffective
# (effectiveness < --min-effectiveness with at least --min-uses).
cmd_prune() {
    _require_jq || return 1
    _ensure_store

    local max_age_days="180" min_eff="0.4" min_uses="5" dry_run="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-age-days) max_age_days="$2"; shift 2 ;;
            --min-effectiveness) min_eff="$2"; shift 2 ;;
            --min-uses) min_uses="$2"; shift 2 ;;
            --dry-run) dry_run="true"; shift ;;
            *) shift ;;
        esac
    done

    local cutoff
    cutoff=$(( $(now_epoch) - (max_age_days * 86400) ))

    local before after removed
    before=$(jq '.patterns | length' "$PATTERNS_FILE")

    local filtered
    filtered=$(jq --argjson cutoff "$cutoff" \
                  --argjson min_eff "$min_eff" \
                  --argjson min_uses "$min_uses" \
                  --arg now "$(now_iso)" '
        .updated_at = $now |
        .patterns = [.patterns[] |
            (.updated_at // .created_at) as $upd |
            ($upd | sub("\\..*"; "Z") | fromdateiso8601? // 0) as $ts |
            select(
                # Keep if recent OR effective enough OR not yet evaluated (uses < min_uses)
                ($ts > $cutoff) or
                (.uses < $min_uses) or
                (.effectiveness >= $min_eff)
            )
        ]
    ' "$PATTERNS_FILE")

    after=$(jq '.patterns | length' <<<"$filtered")
    removed=$(( before - after ))

    if [[ "$dry_run" == "true" ]]; then
        info "Prune (dry-run): would remove $removed of $before patterns"
    else
        _atomic_write "$PATTERNS_FILE" "$filtered"
        success "Pruned $removed patterns (kept $after)"
        emit_event "fleet_patterns_prune" "removed=$removed" "kept=$after"
    fi
}

# ─── Subcommand: stats ─────────────────────────────────────────────────────
cmd_stats() {
    _require_jq || return 1
    _ensure_store

    local want_json="false"
    [[ "${1:-}" == "--json" ]] && want_json="true"

    local stats
    stats=$(jq '
        {
            schema_version: .schema_version,
            total_patterns: (.patterns | length),
            total_uses: ([.patterns[].uses] | add // 0),
            total_successes: ([.patterns[].successes] | add // 0),
            total_failures: ([.patterns[].failures] | add // 0),
            avg_effectiveness: (
                if (.patterns | length) > 0 then
                    ([.patterns[].effectiveness] | add) / (.patterns | length)
                else 0 end
            ),
            unique_repos: ([.patterns[].source_repos[]?] | unique | length),
            top_patterns: (
                .patterns | sort_by(-.uses) | .[0:5] |
                map({id, tech_stack, uses, effectiveness})
            ),
            growth_last_7d: (
                [.patterns[] | select(
                    (.created_at // "" | sub("\\..*"; "Z") | fromdateiso8601? // 0) >
                    (now - 604800)
                )] | length
            ),
            updated_at: .updated_at
        }
    ' "$PATTERNS_FILE")

    if [[ "$want_json" == "true" ]]; then
        echo "$stats"
    else
        info "Fleet Pattern Stats"
        echo "$stats" | jq -r '
            "  Schema:           \(.schema_version)",
            "  Total patterns:   \(.total_patterns)",
            "  Total uses:       \(.total_uses)",
            "  Successes:        \(.total_successes)",
            "  Failures:         \(.total_failures)",
            "  Avg effectiveness: \(.avg_effectiveness | . * 100 | floor)%",
            "  Unique repos:     \(.unique_repos)",
            "  Growth (7d):      \(.growth_last_7d) new patterns",
            "  Updated:          \(.updated_at)"
        '
        local n
        n=$(echo "$stats" | jq '.top_patterns | length')
        if [[ "$n" -gt 0 ]]; then
            echo ""
            info "Top patterns by usage:"
            echo "$stats" | jq -r '.top_patterns[] | "  \(.id) — \(.tech_stack) (uses=\(.uses), eff=\(.effectiveness | . * 100 | floor)%)"'
        fi
    fi
}

# ─── Usage ─────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
shipwright fleet-patterns — Fleet-wide pattern learning (v$VERSION)

Usage: shipwright fleet-patterns <subcommand> [options]

Subcommands:
  extract     Capture a pattern from a successful run
                --tech-stack <s>  --issue-signature <s>  --error-signature <s>
                --root-cause <s>  --fix <s>  --files <csv>  --repo <s>
                --cost <n>  --iterations <n>  --outcome success|failure
  query       Find patterns matching the current context
                --tech-stack <s>  --issue-signature <s>  --error-signature <s>
                --top <n>  --threshold <0-100>  --json
  record-use  Update effectiveness with an outcome
                --id <pattern_id>  --outcome success|failure
                --cost <n>  --iterations <n>
  prune       Evict stale or ineffective patterns
                --max-age-days <n>  --min-effectiveness <0-1>  --min-uses <n>
                --dry-run
  stats       Show pattern library statistics
                [--json]

Storage: $PATTERNS_FILE
EOF
}

# ─── Main ──────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-}"
    [[ $# -gt 0 ]] && shift || true
    case "$cmd" in
        extract) cmd_extract "$@" ;;
        query) cmd_query "$@" ;;
        record-use) cmd_record_use "$@" ;;
        prune) cmd_prune "$@" ;;
        stats) cmd_stats "$@" ;;
        ""|-h|--help|help) usage ;;
        --version) echo "$VERSION" ;;
        *) error "Unknown subcommand: $cmd"; usage; exit 1 ;;
    esac
}

main "$@"
