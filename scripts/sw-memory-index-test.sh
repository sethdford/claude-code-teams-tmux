#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/memory-index test — keyword index build/lookup/validate    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: memory-index Tests"

setup_test_env "sw-memory-index-test"
trap cleanup_test_env EXIT

# Source the module under test (fail-open fallbacks cover missing helpers).
source "$SCRIPT_DIR/lib/memory-index.sh"

# Seed a memory dir with representative content.
MEM="$TEST_TEMP_DIR/memory"
mkdir -p "$MEM"
seed_memory() {
    cat > "$MEM/failures.json" <<'EOF'
{"failures":[
  {"pattern":"mktemp directory missing in sandbox","root_cause":"TMPDIR unset","fix":"use TMPDIR-based mktemp"},
  {"pattern":"output format mismatch","root_cause":"trailing newline","fix":"trim whitespace"}
]}
EOF
    cat > "$MEM/decisions.json" <<'EOF'
{"decisions":[
  {"summary":"use semaphore for timeout","detail":"prevents deadlock in build loop","type":"architecture"}
]}
EOF
    cat > "$MEM/patterns.json" <<'EOF'
{"source_dir":"src/","test_runner":"vitest","import_style":"commonjs"}
EOF
}
seed_memory

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Version signature"
# ═══════════════════════════════════════════════════════════════════════════════

v1=$(memory_index_version "$MEM")
if [[ -n "$v1" && "$v1" != "none" ]]; then
    assert_pass "version() returns a non-empty signature"
else
    assert_fail "version() returns a non-empty signature" "got: $v1"
fi

v1b=$(memory_index_version "$MEM")
assert_eq "version() is stable when files are unchanged" "$v1" "$v1b"

assert_eq "version() of missing dir is 'none'" "none" "$(memory_index_version "$TEST_TEMP_DIR/does-not-exist")"

sleep 1
echo '{"failures":[]}' > "$MEM/failures.json"
v2=$(memory_index_version "$MEM")
if [[ "$v2" != "$v1" ]]; then
    assert_pass "version() changes when a source file changes"
else
    assert_fail "version() changes when a source file changes" "unchanged: $v2"
fi
seed_memory  # restore content for subsequent tests

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Build"
# ═══════════════════════════════════════════════════════════════════════════════

if memory_index_build "$MEM"; then
    assert_pass "build() succeeds on seeded dir"
else
    assert_fail "build() succeeds on seeded dir"
fi

assert_file_exists "build() writes index.json" "$MEM/index.json"

idx=$(cat "$MEM/index.json")
assert_json_key "index has schema_version 1" "$idx" ".schema_version" "1"

kw_count=$(jq -r '.keywords | length' "$MEM/index.json")
assert_gt "index contains multiple keywords" "$kw_count" "3"

stored_ver=$(jq -r '.version' "$MEM/index.json")
assert_eq "index records the current source version" "$(memory_index_version "$MEM")" "$stored_ver"

# No leftover temp/lock artifacts in the dir besides known files.
leftover=$(ls "$MEM"/index.json.tmp.* 2>/dev/null | wc -l | tr -d ' ' || true)
leftover="${leftover:-0}"
assert_eq "build() leaves no temp files behind" "0" "$leftover"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Lookup"
# ═══════════════════════════════════════════════════════════════════════════════

assert_eq "lookup() finds failure entry by keyword" "failure:0" "$(memory_index_lookup "$MEM" mktemp)"
assert_eq "lookup() finds decision entry by keyword" "decision:0" "$(memory_index_lookup "$MEM" timeout)"
assert_eq "lookup() finds pattern entry by keyword" "pattern:0" "$(memory_index_lookup "$MEM" vitest)"
assert_eq "lookup() is case-insensitive" "decision:0" "$(memory_index_lookup "$MEM" TIMEOUT)"
assert_eq "lookup() returns empty for unknown keyword" "" "$(memory_index_lookup "$MEM" zzznomatch)"

# A keyword shared across sources returns multiple refs.
echo '{"failures":[{"pattern":"vitest runner crashed","root_cause":"x","fix":"y"}]}' > "$MEM/failures.json"
memory_index_build "$MEM"
multi=$(memory_index_lookup "$MEM" vitest | sort | tr '\n' ',')
assert_contains "lookup() returns failure ref for shared keyword" "$multi" "failure:0"
assert_contains "lookup() returns pattern ref for shared keyword" "$multi" "pattern:0"
seed_memory
memory_index_build "$MEM"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Validate & self-heal"
# ═══════════════════════════════════════════════════════════════════════════════

if memory_index_validate "$MEM"; then
    assert_pass "validate() returns 0 for a fresh index"
else
    assert_fail "validate() returns 0 for a fresh index"
fi

# Staleness: editing a source file invalidates the index.
sleep 1
echo '{"failures":[{"pattern":"brand new failure entry","root_cause":"x","fix":"y"}]}' > "$MEM/failures.json"
if memory_index_validate "$MEM"; then
    assert_fail "validate() detects a stale index"
else
    assert_pass "validate() detects a stale index"
fi

# Lookup self-heals a stale index, returning fresh results.
healed=$(memory_index_lookup "$MEM" brand)
assert_eq "lookup() self-heals stale index and finds new entry" "failure:0" "$healed"
if memory_index_validate "$MEM"; then
    assert_pass "index is fresh again after self-heal"
else
    assert_fail "index is fresh again after self-heal"
fi

# Corruption: garbage index.json is treated as invalid, then rebuilt.
echo 'this is not json {{{' > "$MEM/index.json"
if memory_index_validate "$MEM"; then
    assert_fail "validate() rejects a corrupt index"
else
    assert_pass "validate() rejects a corrupt index"
fi
memory_index_lookup "$MEM" brand >/dev/null
if memory_index_validate "$MEM"; then
    assert_pass "corrupt index is rebuilt on next lookup"
else
    assert_fail "corrupt index is rebuilt on next lookup"
fi

# Wrong schema version is rejected (forces format migrations to rebuild).
jq '.schema_version = 999' "$MEM/index.json" > "$MEM/index.json.tmp" && mv "$MEM/index.json.tmp" "$MEM/index.json"
if memory_index_validate "$MEM"; then
    assert_fail "validate() rejects a mismatched schema version"
else
    assert_pass "validate() rejects a mismatched schema version"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Edge cases"
# ═══════════════════════════════════════════════════════════════════════════════

# Empty memory dir: build still succeeds and produces an empty keyword map.
EMPTY="$TEST_TEMP_DIR/empty-memory"
mkdir -p "$EMPTY"
if memory_index_build "$EMPTY"; then
    assert_pass "build() succeeds on an empty memory dir"
else
    assert_fail "build() succeeds on an empty memory dir"
fi
assert_eq "empty dir yields zero keywords" "0" "$(jq -r '.keywords | length' "$EMPTY/index.json")"
assert_eq "lookup() on empty index returns nothing" "" "$(memory_index_lookup "$EMPTY" anything)"

# Missing-dir lookups are safe no-ops (fail-open).
assert_eq "lookup() on missing dir returns nothing" "" "$(memory_index_lookup "$TEST_TEMP_DIR/nope" anything)"

# Blank keyword is a safe no-op.
assert_eq "lookup() with empty keyword returns nothing" "" "$(memory_index_lookup "$MEM" "")"

# Malformed source JSON is skipped, not fatal.
echo 'BROKEN{{' > "$MEM/decisions.json"
seed_failures_only=$(memory_index_build "$MEM" && echo ok || echo fail)
assert_eq "build() tolerates a malformed source file" "ok" "$seed_failures_only"

print_test_results
