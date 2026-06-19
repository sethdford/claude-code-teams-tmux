#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright memory-bench — Memory query latency benchmark & parity gate     ║
# ║  Generates a realistic corpus (default N=500), then measures cold-lookup    ║
# ║  latency for the legacy full scan (index OFF) vs the L2-indexed scan        ║
# ║  (index ON). Asserts (1) byte-identical results between the two paths and   ║
# ║  (2) indexed cold p95 < 100ms. Reports p50/p95/p99 — not just the mean.     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   sw-memory-bench.sh run [--n N] [--out FILE] [--iterations K]
#   sw-memory-bench.sh check            # run with the default gate, exit 1 on miss
#
# "Cold" = the L1 result cache is cleared before every measured query, so each
# sample reflects a real scan (the worst case the <100ms target must hold for).
set -uo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Fail-open library load (bench must run standalone) ──────────────────────
source "$SCRIPT_DIR/lib/memory-index.sh"
source "$SCRIPT_DIR/lib/memory-cache.sh"
source "$SCRIPT_DIR/lib/memory-query.sh"

P95_TARGET_MS="${SW_MEMORY_P95_TARGET_MS:-100}"

# Representative query mix: substring hits, multi-token, type-spanning, misses.
BENCH_QUERIES=(
    "test deploy failure"
    "auth token expired"
    "database migration schema"
    "api endpoint latency"
    "performance optimization cache"
    "credential refresh"
    "nonexistent zzz query"
    "latest"
)

# ─── Generate a realistic corpus into $1 (failures + decisions + patterns) ────
_bench_gen_corpus() {
    local dir="$1" n="$2" i sep eff
    {
        echo '{"failures":['
        for ((i = 0; i < n; i++)); do
            sep=,; [[ $i -eq 0 ]] && sep=
            eff=$(( i % 100 ))
            printf '%s{"pattern":"test failure %d during deploy stage","root_cause":"auth token expired in session %d","fix":"refresh the credential cache and retry","fix_effectiveness_rate":%d}' \
                "$sep" "$i" "$i" "$eff"
        done
        echo ']}'
    } > "$dir/failures.json"
    local d=$(( n / 4 ))
    {
        echo '{"decisions":['
        for ((i = 0; i < d; i++)); do
            sep=,; [[ $i -eq 0 ]] && sep=
            printf '%s{"summary":"chose database migration strategy variant %d","detail":"use sql schema versioning with rollback","type":"architecture"}' \
                "$sep" "$i"
        done
        echo ']}'
    } > "$dir/decisions.json"
    echo '{"project":"shipwright","conventions":"bash 3.2 compatible","known_issues":["api endpoint latency spikes under load","performance optimization needed for cache layer"]}' \
        > "$dir/patterns.json"
}

# ─── Percentile of a sorted-on-the-fly integer list on stdin ─────────────────
# $1 = percentile (e.g. 95). Reads whitespace/newline-separated ms samples.
_bench_pct() {
    local p="$1"
    sort -n | awk -v p="$p" '
        { a[NR]=$1 }
        END {
            if (NR==0) { print 0; exit }
            idx = int((p/100.0)*NR + 0.999999); if (idx<1) idx=1; if (idx>NR) idx=NR
            print a[idx]
        }'
}

# ─── Measure cold-lookup latency for one path; echoes "p50 p95 p99" ──────────
# $1=dir $2=index_flag(0|1) $3=iterations
_bench_measure() {
    local dir="$1" idx_flag="$2" iters="$3"
    local samples q t0 t1 k
    samples=$(mktemp)
    for ((k = 0; k < iters; k++)); do
        for q in "${BENCH_QUERIES[@]}"; do
            memory_cache_clear "$dir" >/dev/null 2>&1 || true   # force a cold scan
            t0=$(_memory_query_now_ms)
            SW_MEMORY_CACHE=0 SW_MEMORY_INDEX="$idx_flag" \
                memory_ranked_search "$q" "$dir" 5 >/dev/null 2>&1 || true
            t1=$(_memory_query_now_ms)
            echo $(( t1 - t0 )) >> "$samples"
        done
    done
    local p50 p95 p99
    p50=$(_bench_pct 50 < "$samples")
    p95=$(_bench_pct 95 < "$samples")
    p99=$(_bench_pct 99 < "$samples")
    rm -f "$samples"
    echo "$p50 $p95 $p99"
}

# ─── Verify index-on and index-off are byte-identical over the query mix ──────
_bench_parity() {
    local dir="$1" q off on
    for q in "${BENCH_QUERIES[@]}"; do
        off=$(SW_MEMORY_CACHE=0 SW_MEMORY_INDEX=0 memory_ranked_search "$q" "$dir" 5 2>/dev/null)
        on=$(SW_MEMORY_CACHE=0 SW_MEMORY_INDEX=1 memory_ranked_search "$q" "$dir" 5 2>/dev/null)
        [[ "$off" == "$on" ]] || { echo "$q"; return 1; }
    done
    return 0
}

cmd_run() {
    local n=500 iters=3 out=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --n) n="$2"; shift 2 ;;
            --iterations) iters="$2"; shift 2 ;;
            --out) out="$2"; shift 2 ;;
            *) echo "unknown arg: $1" >&2; return 2 ;;
        esac
    done

    local dir; dir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$dir'" EXIT

    echo "▸ Generating corpus (N=$n failures, $(( n / 4 )) decisions)…"
    _bench_gen_corpus "$dir" "$n"

    echo "▸ Building L2 index…"
    memory_index_build "$dir" >/dev/null 2>&1 || true

    echo "▸ Verifying index-on/off parity…"
    local parity="pass" bad_q
    if ! bad_q=$(_bench_parity "$dir"); then
        parity="fail"
        echo "  ✗ PARITY FAILURE on query: $bad_q" >&2
    else
        echo "  ✓ byte-identical across ${#BENCH_QUERIES[@]} queries"
    fi

    echo "▸ Measuring cold-scan latency ($iters iterations × ${#BENCH_QUERIES[@]} queries)…"
    local off_stats on_stats
    off_stats=$(_bench_measure "$dir" 0 "$iters")   # baseline: full scan
    on_stats=$(_bench_measure "$dir" 1 "$iters")    # after: indexed scan

    local off_p50 off_p95 off_p99 on_p50 on_p95 on_p99
    read -r off_p50 off_p95 off_p99 <<< "$off_stats"
    read -r on_p50 on_p95 on_p99 <<< "$on_stats"

    local target_met="true"
    [[ "$on_p95" -ge "$P95_TARGET_MS" ]] && target_met="false"

    printf '\n  %-18s %8s %8s %8s\n' "path" "p50(ms)" "p95(ms)" "p99(ms)"
    printf '  %-18s %8s %8s %8s\n' "index OFF (full)" "$off_p50" "$off_p95" "$off_p99"
    printf '  %-18s %8s %8s %8s\n' "index ON  (L2)"   "$on_p50"  "$on_p95"  "$on_p99"
    printf '  target: indexed cold p95 < %sms → %s\n\n' "$P95_TARGET_MS" \
        "$([[ "$target_met" == "true" ]] && echo PASS || echo FAIL)"

    local json
    json=$(jq -n \
        --argjson n "$n" --argjson iters "$iters" \
        --argjson target "$P95_TARGET_MS" \
        --arg parity "$parity" --arg target_met "$target_met" \
        --argjson off_p50 "$off_p50" --argjson off_p95 "$off_p95" --argjson off_p99 "$off_p99" \
        --argjson on_p50 "$on_p50" --argjson on_p95 "$on_p95" --argjson on_p99 "$on_p99" \
        '{
            corpus_size: $n, iterations: $iters, p95_target_ms: $target,
            parity: $parity, p95_target_met: ($target_met == "true"),
            index_off: { p50_ms: $off_p50, p95_ms: $off_p95, p99_ms: $off_p99 },
            index_on:  { p50_ms: $on_p50,  p95_ms: $on_p95,  p99_ms: $on_p99 }
        }')
    if [[ -n "$out" ]]; then
        printf '%s\n' "$json" > "$out"
        echo "▸ Results written to $out"
    else
        printf '%s\n' "$json"
    fi

    [[ "$parity" == "pass" && "$target_met" == "true" ]] && return 0
    return 1
}

case "${1:-run}" in
    run)   shift; cmd_run "$@" ;;
    check) shift; cmd_run "$@" ;;
    --version|version) echo "$VERSION" ;;
    *) echo "usage: sw-memory-bench.sh {run|check} [--n N] [--iterations K] [--out FILE]" >&2; exit 2 ;;
esac
