#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/memory-cache test — query result cache get/put/invalidate  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: memory-cache Tests"

setup_test_env "sw-memory-cache-test"
trap cleanup_test_env EXIT

# Source the module under test (pulls in memory-index for versioning).
source "$SCRIPT_DIR/lib/memory-cache.sh"

HAVE_SQLITE=0
command -v sqlite3 >/dev/null 2>&1 && HAVE_SQLITE=1

# Seed a memory dir with representative content.
MEM="$TEST_TEMP_DIR/memory"
mkdir -p "$MEM"
seed_memory() {
    cat > "$MEM/failures.json" <<'EOF'
{"failures":[{"pattern":"mktemp fails in sandbox","root_cause":"TMPDIR unset","fix":"use TMPDIR mktemp"}]}
EOF
    cat > "$MEM/decisions.json" <<'EOF'
{"decisions":[{"summary":"semaphore for timeout","detail":"prevents hang","type":"pattern"}]}
EOF
    cat > "$MEM/patterns.json" <<'EOF'
{"source_dir":"src/","test_runner":"vitest"}
EOF
}
seed_memory

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Cache key"
# ═══════════════════════════════════════════════════════════════════════════════

k1=$(memory_cache_key "$MEM" "mktemp timeout" 5)
k2=$(memory_cache_key "$MEM" "mktemp timeout" 5)
assert_eq "key is deterministic for same inputs" "$k1" "$k2"

k3=$(memory_cache_key "$MEM" "different query" 5)
if [[ "$k1" != "$k3" ]]; then
    assert_pass "key differs for a different query"
else
    assert_fail "key differs for a different query" "both: $k1"
fi

k4=$(memory_cache_key "$MEM" "mktemp timeout" 10)
if [[ "$k1" != "$k4" ]]; then
    assert_pass "key differs for a different max_results"
else
    assert_fail "key differs for a different max_results" "both: $k1"
fi

# Key version prefix changes when a source file changes (auto-invalidation).
sleep 1
echo '{"failures":[{"pattern":"changed","root_cause":"c","fix":"f"}]}' > "$MEM/failures.json"
k5=$(memory_cache_key "$MEM" "mktemp timeout" 5)
if [[ "$k1" != "$k5" ]]; then
    assert_pass "key changes when a source file changes"
else
    assert_fail "key changes when a source file changes" "unchanged: $k1"
fi
seed_memory  # restore

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Get / put round-trip"
# ═══════════════════════════════════════════════════════════════════════════════

# Cold get is a miss.
if memory_cache_get "$MEM" "q1" 5 >/dev/null 2>&1; then
    assert_fail "cold get is a miss" "unexpected hit"
else
    assert_pass "cold get is a miss"
fi

VALUE='[{"source_type":"failure","content_text":"hello | world"}]'
if [[ "$HAVE_SQLITE" -eq 1 ]]; then
    memory_cache_put "$MEM" "q1" 5 "$VALUE"
    got=$(memory_cache_get "$MEM" "q1" 5) && hit=0 || hit=1
    assert_eq "put then get hits" "0" "$hit"
    assert_eq "cached value is byte-identical" "$VALUE" "$got"

    # A multi-line (pretty JSON) value survives the round-trip intact.
    ML=$'[\n  {\n    "k": "v"\n  }\n]'
    memory_cache_put "$MEM" "qml" 5 "$ML"
    gotml=$(memory_cache_get "$MEM" "qml" 5)
    assert_eq "multi-line value round-trips intact" "$ML" "$gotml"
else
    assert_pass "put then get hits (skipped: no sqlite3)"
    assert_pass "cached value is byte-identical (skipped: no sqlite3)"
    assert_pass "multi-line value round-trips intact (skipped: no sqlite3)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Invalidation"
# ═══════════════════════════════════════════════════════════════════════════════

if [[ "$HAVE_SQLITE" -eq 1 ]]; then
    memory_cache_put "$MEM" "q2" 5 "OLD"
    # Change a source file -> version (and key) changes -> old entry is a miss.
    sleep 1
    echo '{"failures":[{"pattern":"v2","root_cause":"r","fix":"f"}]}' > "$MEM/failures.json"
    if memory_cache_get "$MEM" "q2" 5 >/dev/null 2>&1; then
        assert_fail "stale entry misses after source change" "unexpected hit"
    else
        assert_pass "stale entry misses after source change"
    fi
    # A put under the new version prunes the old-version row.
    memory_cache_put "$MEM" "q2" 5 "NEW"
    rows=$(sqlite3 "$MEM/.query-cache.db" "SELECT count(*) FROM query_cache;" 2>/dev/null || echo "?")
    assert_eq "old-version rows are pruned on put" "1" "$rows"
    seed_memory

    # TTL expiry: a row older than the TTL is a miss.
    SW_MEMORY_CACHE_TTL=0 memory_cache_put "$MEM" "q3" 5 "EXPIRES"
    if SW_MEMORY_CACHE_TTL=0 memory_cache_get "$MEM" "q3" 5 >/dev/null 2>&1; then
        assert_fail "TTL-expired entry misses" "unexpected hit"
    else
        assert_pass "TTL-expired entry misses"
    fi

    # clear drops everything.
    memory_cache_put "$MEM" "q4" 5 "X"
    memory_cache_clear "$MEM"
    cleared=$(sqlite3 "$MEM/.query-cache.db" "SELECT count(*) FROM query_cache;" 2>/dev/null || echo "?")
    assert_eq "clear drops all rows" "0" "$cleared"
else
    assert_pass "stale entry misses after source change (skipped: no sqlite3)"
    assert_pass "old-version rows are pruned on put (skipped: no sqlite3)"
    assert_pass "TTL-expired entry misses (skipped: no sqlite3)"
    assert_pass "clear drops all rows (skipped: no sqlite3)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Fail-open & edge cases"
# ═══════════════════════════════════════════════════════════════════════════════

# Missing dir: get misses, put is a no-op, clear is harmless — none error.
if memory_cache_get "$TEST_TEMP_DIR/nope" "q" 5 >/dev/null 2>&1; then
    assert_fail "get on missing dir misses" "unexpected hit"
else
    assert_pass "get on missing dir misses"
fi
if memory_cache_put "$TEST_TEMP_DIR/nope" "q" 5 "v" >/dev/null 2>&1; then
    assert_fail "put on missing dir is a no-op" "unexpected success"
else
    assert_pass "put on missing dir is a no-op"
fi
memory_cache_clear "$TEST_TEMP_DIR/nope" && assert_pass "clear on missing dir is harmless" \
    || assert_fail "clear on missing dir is harmless" "non-zero exit"

# Empty value is treated as a miss (an empty cell carries no result).
if [[ "$HAVE_SQLITE" -eq 1 ]]; then
    memory_cache_put "$MEM" "qempty" 5 ""
    if memory_cache_get "$MEM" "qempty" 5 >/dev/null 2>&1; then
        assert_fail "empty cached value is a miss" "unexpected hit"
    else
        assert_pass "empty cached value is a miss"
    fi
else
    assert_pass "empty cached value is a miss (skipped: no sqlite3)"
fi

# SQL-injection-ish content with single quotes is stored/retrieved safely.
if [[ "$HAVE_SQLITE" -eq 1 ]]; then
    TRICKY="value with ' single ' quotes and ; semicolons"
    memory_cache_put "$MEM" "qtricky" 5 "$TRICKY"
    gott=$(memory_cache_get "$MEM" "qtricky" 5)
    assert_eq "quotes/semicolons survive escaping" "$TRICKY" "$gott"
else
    assert_pass "quotes/semicolons survive escaping (skipped: no sqlite3)"
fi

echo ""
print_test_results
