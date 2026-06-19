#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-issue-clustering.sh — Semantic Issue Clustering Engine                ║
# ║                                                                          ║
# ║  Clusters historical issues from events.jsonl (TF-IDF + cosine), stores  ║
# ║  them in ~/.shipwright/issue-clusters.json, and matches new issues to    ║
# ║  the nearest cluster so pipelines can reuse approaches that worked.       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.3.0"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Canonical helpers (colors, output, events, _smart_int)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() {
    local t="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local p="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$t\""
    while [[ $# -gt 0 ]]; do local k="${1%%=*}" v="${1#*=}"; p="${p},\"${k}\":\"${v}\""; shift; done
    echo "${p}}" >> "${HOME}/.shipwright/events.jsonl"
}
# Minimal _smart_int fallback (key default) for standalone/test use.
[[ "$(type -t _smart_int 2>/dev/null)" == "function" ]] || _smart_int() {
    local key="$1" default="$2"
    local env_key; env_key="SW_$(echo "$key" | tr '[:lower:].' '[:upper:]_')"
    local env_val=""; eval 'env_val="${'"$env_key"':-}"' 2>/dev/null || true
    [[ -n "$env_val" ]] && { echo "$env_val"; return; }
    echo "$default"
}

# Resolve paths (overridable via env for tests).
SHIPWRIGHT_HOME="${SHIPWRIGHT_HOME:-$HOME/.shipwright}"
EVENTS_FILE="${SW_CLUSTERING_EVENTS:-$SHIPWRIGHT_HOME/events.jsonl}"
CLUSTERS_FILE="${SW_CLUSTERING_OUTPUT:-$SHIPWRIGHT_HOME/issue-clusters.json}"
ALGO_JS="${SW_CLUSTERING_ALGO:-$REPO_ROOT/src/issue-clustering.js}"
LAST_RUN_FILE="$SHIPWRIGHT_HOME/.clustering-last-run"

show_help() {
    cat <<EOF
USAGE
  shipwright clustering <command> [OPTIONS]

DESCRIPTION
  Semantic Issue Clustering Engine. Groups historical issues from events.jsonl
  by similarity (TF-IDF + cosine) and recommends proven approaches for new issues.

COMMANDS
  run               Re-cluster issues from events.jsonl into issue-clusters.json
  match <text>      Match an issue (free text or JSON) to the nearest cluster
  show              Print the current clusters
  status            Show cluster count, age, and freshness
  metrics           Show match rate and mean cluster success rate
  due               Exit 0 if a weekly re-cluster is due, else exit 1

OPTIONS
  --threshold N     Similarity cutoff (0.0–1.0); overrides config
  --help, -h        Show this help text
  --version, -v     Show version

EXAMPLES
  shipwright clustering run
  shipwright clustering match "daemon timeout SIGKILL"
  shipwright clustering show
EOF
}

# Read clustering config with sane defaults.
_cfg_threshold() { _smart_int "clustering.similarity_threshold" "0.5"; }
_cfg_max_events() { _smart_int "clustering.max_events" "500"; }
_cfg_min_size()  { _smart_int "clustering.min_cluster_size" "2"; }
_cfg_max_clusters() { _smart_int "clustering.max_clusters" "50"; }
_cfg_interval_days() { _smart_int "clustering.re_cluster_interval_days" "7"; }

# Run clustering: read recent events, invoke the Node algorithm, atomically write.
_clustering_run() {
    local threshold="${1:-$(_cfg_threshold)}"
    mkdir -p "$SHIPWRIGHT_HOME"

    if [[ ! -f "$EVENTS_FILE" ]]; then
        warn "No events file at $EVENTS_FILE — writing empty clusters"
    fi
    if [[ ! -f "$ALGO_JS" ]]; then
        error "Clustering algorithm not found at $ALGO_JS"
        return 1
    fi

    local max_events min_size max_clusters generated_at
    max_events="$(_cfg_max_events)"
    min_size="$(_cfg_min_size)"
    max_clusters="$(_cfg_max_clusters)"
    generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    emit_event "clustering.started" "events_file=$EVENTS_FILE"

    # Build a JSON array of the last N valid events. Invalid lines are skipped
    # (jq -c parses each line; failures are dropped) to survive partial writes.
    local batch_file; batch_file="$(mktemp "${TMPDIR:-/tmp}/sw-clustering-batch.XXXXXX")"
    local temp_out;   temp_out="$(mktemp "${TMPDIR:-/tmp}/sw-clustering-out.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$batch_file' '$temp_out'" RETURN

    if [[ -f "$EVENTS_FILE" ]]; then
        tail -n "$max_events" "$EVENTS_FILE" 2>/dev/null \
            | jq -c '.' 2>/dev/null \
            | jq -s '.' > "$batch_file" 2>/dev/null || echo '[]' > "$batch_file"
    else
        echo '[]' > "$batch_file"
    fi
    [[ -s "$batch_file" ]] || echo '[]' > "$batch_file"

    if ! node "$ALGO_JS" cluster \
            --threshold "$threshold" \
            --min-size "$min_size" \
            --max-clusters "$max_clusters" \
            --generated-at "$generated_at" \
            < "$batch_file" > "$temp_out" 2>/dev/null; then
        error "Clustering algorithm failed"
        emit_event "clustering.failed" "reason=algorithm_error"
        return 1
    fi

    # Validate output is well-formed JSON before committing.
    if ! jq empty < "$temp_out" 2>/dev/null; then
        error "Clustering produced invalid JSON — keeping previous clusters"
        emit_event "clustering.failed" "reason=invalid_output"
        return 1
    fi

    # Atomic write: temp file then mv (same dir for atomicity on POSIX).
    local atomic_tmp="${CLUSTERS_FILE}.tmp.$$"
    cp "$temp_out" "$atomic_tmp"
    mv "$atomic_tmp" "$CLUSTERS_FILE"
    date +%s > "$LAST_RUN_FILE"

    local cluster_count total_issues
    cluster_count="$(jq '.clusters | length' "$CLUSTERS_FILE" 2>/dev/null || echo 0)"
    total_issues="$(jq '.metadata.total_issues_processed' "$CLUSTERS_FILE" 2>/dev/null || echo 0)"

    emit_event "clustering.completed" \
        "cluster_count=$cluster_count" \
        "total_issues=$total_issues"

    success "Clustering complete: $cluster_count clusters from $total_issues issues"
}

# Match a new issue (free text or JSON) to the nearest cluster.
_clustering_match() {
    local query="$1" threshold="${2:-$(_cfg_threshold)}"
    if [[ ! -f "$CLUSTERS_FILE" ]]; then
        warn "No clusters file — run 'shipwright clustering run' first"
        echo "null"
        return 0
    fi
    if [[ ! -f "$ALGO_JS" ]]; then
        error "Clustering algorithm not found at $ALGO_JS"
        return 1
    fi

    # Accept either a JSON object or free text. Free text becomes {title:text}.
    local issue_json
    if echo "$query" | jq empty 2>/dev/null && [[ "$query" == "{"* ]]; then
        issue_json="$query"
    else
        issue_json="$(jq -n --arg t "$query" '{title:$t}')"
    fi

    local match
    match="$(jq -n --argjson issue "$issue_json" --slurpfile c "$CLUSTERS_FILE" \
        '{issue:$issue, clusters:$c[0]}' \
        | node "$ALGO_JS" match --threshold "$threshold" 2>/dev/null)" || {
        error "Matching failed"
        return 1
    }

    echo "$match"
    if [[ "$match" != "null" && -n "$match" ]]; then
        local cid sim
        cid="$(echo "$match" | jq -r '.cluster_id' 2>/dev/null || echo "")"
        sim="$(echo "$match" | jq -r '.similarity_score' 2>/dev/null || echo "")"
        [[ -n "$cid" && "$cid" != "null" ]] && emit_event "clustering.matched" \
            "cluster_id=$cid" "similarity_score=$sim"
    fi
}

_clustering_show() {
    if [[ ! -f "$CLUSTERS_FILE" ]]; then
        warn "No clusters file at $CLUSTERS_FILE"
        return 0
    fi
    jq '.' "$CLUSTERS_FILE"
}

_clustering_status() {
    if [[ ! -f "$CLUSTERS_FILE" ]]; then
        info "No clusters generated yet"
        return 0
    fi
    local count generated age_days now gen_epoch
    count="$(jq '.clusters | length' "$CLUSTERS_FILE" 2>/dev/null || echo 0)"
    generated="$(jq -r '.generated_at' "$CLUSTERS_FILE" 2>/dev/null || echo "unknown")"
    now="$(date +%s)"
    gen_epoch="$(date -d "$generated" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$generated" +%s 2>/dev/null || echo "$now")"
    age_days=$(( (now - gen_epoch) / 86400 ))
    info "Clusters: $count"
    info "Generated: $generated (${age_days}d ago)"
}

# Report clustering effectiveness metrics from events.jsonl: how often new
# issues match a cluster, and the mean success rate of matched clusters.
_clustering_metrics() {
    local events="$EVENTS_FILE"
    if [[ ! -f "$events" ]]; then
        info "No events file — no metrics yet"
        return 0
    fi

    local matched total_clusters avg_cluster_success
    # Count clustering.matched events (a match means the new issue found a cluster).
    matched="$(grep -c '"type":"clustering.matched"' "$events" 2>/dev/null || true)"
    matched="${matched:-0}"

    if [[ -f "$CLUSTERS_FILE" ]]; then
        total_clusters="$(jq '.clusters | length' "$CLUSTERS_FILE" 2>/dev/null || echo 0)"
        # Mean success rate across clusters that have an outcome-bearing rate.
        avg_cluster_success="$(jq -r '
            [.clusters[].success_metrics.success_rate | select(. != null)] as $r
            | if ($r | length) > 0 then (($r | add) / ($r | length)) else null end
        ' "$CLUSTERS_FILE" 2>/dev/null || echo "null")"
    else
        total_clusters=0
        avg_cluster_success="null"
    fi

    # Human summary to stderr so stdout stays pure JSON (pipeable, like 'match').
    info "Pattern matches recorded: $matched" >&2
    info "Clusters: $total_clusters" >&2
    if [[ "$avg_cluster_success" != "null" && -n "$avg_cluster_success" ]]; then
        info "Mean cluster success rate: $avg_cluster_success" >&2
    else
        info "Mean cluster success rate: n/a (no outcomes yet)" >&2
    fi

    # Machine-readable line for dashboards/aggregators.
    jq -n \
        --argjson matched "${matched:-0}" \
        --argjson clusters "${total_clusters:-0}" \
        --argjson success "${avg_cluster_success:-null}" \
        '{pattern_matches: $matched, clusters: $clusters, mean_cluster_success_rate: $success}'
}

# Exit 0 when a weekly re-cluster is due (used by the daemon poll loop).
_clustering_due() {
    local interval_days last now interval_s
    interval_days="$(_cfg_interval_days)"
    interval_s=$(( interval_days * 86400 ))
    now="$(date +%s)"
    if [[ ! -f "$LAST_RUN_FILE" ]]; then
        return 0
    fi
    last="$(cat "$LAST_RUN_FILE" 2>/dev/null || echo 0)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if (( now - last >= interval_s )); then
        return 0
    fi
    return 1
}

main() {
    local cmd="${1:-}"
    [[ $# -gt 0 ]] && shift || true

    # Extract --threshold if present.
    local threshold="" positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --threshold) threshold="${2:-}"; shift 2 ;;
            -h|--help)   show_help; return 0 ;;
            -v|--version) echo "$VERSION"; return 0 ;;
            *) positional+=("$1"); shift ;;
        esac
    done

    case "$cmd" in
        run)    _clustering_run "${threshold:-$(_cfg_threshold)}" ;;
        match)  _clustering_match "${positional[0]:-}" "${threshold:-$(_cfg_threshold)}" ;;
        show)   _clustering_show ;;
        status) _clustering_status ;;
        metrics) _clustering_metrics ;;
        due)    _clustering_due ;;
        -h|--help|help|"") show_help ;;
        -v|--version) echo "$VERSION" ;;
        *) error "Unknown command: $cmd"; show_help; return 1 ;;
    esac
}

main "$@"
