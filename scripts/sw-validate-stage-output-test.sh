#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-validate-stage-output-test.sh — Stage Output Validator Test Suite     ║
# ║                                                                          ║
# ║  Unit + integration tests for scripts/lib/validate.sh and the CLI.        ║
# ║  Test pyramid: ~22 unit (lib functions, contract subset, error codes),    ║
# ║  ~8 integration (CLI flags, strict/warn, lint, metrics). No real Claude/  ║
# ║  GitHub calls — pure filesystem fixtures in an isolated TMPDIR.            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

GREEN=$'\033[38;2;74;222;128m'
RED=$'\033[38;2;248;113;113m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

# ─── Isolated sandbox ───────────────────────────────────────────────────────
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sw-validate-test.XXXXXX")"
export VALIDATION_SCHEMA_DIR="$TEST_ROOT/schemas"
export VALIDATION_METRICS_FILE="$TEST_ROOT/metrics.jsonl"
export HOME="$TEST_ROOT/home"   # isolate any stray writes
mkdir -p "$VALIDATION_SCHEMA_DIR" "$HOME"

cleanup() { rm -rf "$TEST_ROOT" 2>/dev/null || true; }
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2; cleanup' ERR
trap cleanup EXIT

# ─── Assert helpers ─────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" desc="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS+1)); echo "  ${GREEN}${BOLD}✓${RESET} $desc"
    else
        FAIL=$((FAIL+1)); echo "  ${RED}${BOLD}✗${RESET} $desc"
        echo "    Expected: $expected"; echo "    Actual:   $actual"
    fi
}
assert_contains() {
    local haystack="$1" needle="$2" desc="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS+1)); echo "  ${GREEN}${BOLD}✓${RESET} $desc"
    else
        FAIL=$((FAIL+1)); echo "  ${RED}${BOLD}✗${RESET} $desc"
        echo "    Expected to contain: $needle"; echo "    In: $haystack"
    fi
}
assert_exit() {
    local expected="$1" actual="$2" desc="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS+1)); echo "  ${GREEN}${BOLD}✓${RESET} $desc"
    else
        FAIL=$((FAIL+1)); echo "  ${RED}${BOLD}✗${RESET} $desc"
        echo "    Expected exit: $expected"; echo "    Actual exit:   $actual"
    fi
}

# Helper: write a schema file
mk_schema() { printf '%s' "$2" > "$VALIDATION_SCHEMA_DIR/$1.schema.json"; }
# Helper: extract a field from a result JSON
field() { echo "$1" | jq -r "$2"; }

# Source the library under test.
# shellcheck source=lib/validate.sh
source "$SCRIPT_DIR/lib/validate.sh"

CLI="$SCRIPT_DIR/sw-validate-stage-output.sh"

# ═══════════════════════════════════════════════════════════════════════════
# UNIT TESTS — load_schema
# ═══════════════════════════════════════════════════════════════════════════
test_load_schema() {
    echo "▸ load_schema"
    mk_schema demo '{"type":"object"}'
    local out rc
    out="$(load_schema demo)"; rc=$?
    assert_exit 0 "$rc" "load_schema returns 0 when schema exists"
    assert_contains "$out" "demo.schema.json" "load_schema echoes resolved path"
    set +e; load_schema nonexistent >/dev/null 2>&1; rc=$?; set -e
    assert_exit 1 "$rc" "load_schema returns 1 when schema missing"
}

# ═══════════════════════════════════════════════════════════════════════════
# UNIT TESTS — lint_schema
# ═══════════════════════════════════════════════════════════════════════════
test_lint_schema() {
    echo "▸ lint_schema"
    mk_schema good '{"type":"object","required":["a"],"properties":{"a":{"type":"string"}}}'
    set +e; lint_schema "$VALIDATION_SCHEMA_DIR/good.schema.json" 2>/dev/null; local rc=$?; set -e
    assert_exit 0 "$rc" "lint passes a supported schema"

    printf '%s' 'not json{' > "$VALIDATION_SCHEMA_DIR/broken.schema.json"
    set +e; lint_schema "$VALIDATION_SCHEMA_DIR/broken.schema.json" 2>/dev/null; rc=$?; set -e
    assert_exit 1 "$rc" "lint fails unparseable JSON"

    mk_schema refy '{"type":"object","properties":{"a":{"$ref":"#/x"}}}'
    set +e; lint_schema "$VALIDATION_SCHEMA_DIR/refy.schema.json" 2>/dev/null; rc=$?; set -e
    assert_exit 1 "$rc" "lint fails schema with unsupported \$ref keyword"

    mk_schema oneof '{"type":"object","oneOf":[{"required":["a"]}]}'
    set +e; lint_schema "$VALIDATION_SCHEMA_DIR/oneof.schema.json" 2>/dev/null; rc=$?; set -e
    assert_exit 1 "$rc" "lint fails schema with unsupported oneOf keyword"
}

# ═══════════════════════════════════════════════════════════════════════════
# UNIT TESTS — validate_stage_output happy/contract paths
# ═══════════════════════════════════════════════════════════════════════════
test_valid_json() {
    echo "▸ validate_stage_output — valid JSON"
    mk_schema s1 '{"type":"object","required":["goal"],"properties":{"goal":{"type":"string"},"n":{"type":"number"}}}'
    echo '{"goal":"x","n":5}' > "$TEST_ROOT/a.json"
    local r rc
    r="$(validate_stage_output s1 "$TEST_ROOT/a.json")"; rc=$?
    assert_exit 0 "$rc" "exit 0 for completed validation"
    assert_equals true "$(field "$r" .valid)" "valid=true for conforming artifact"
    assert_equals 0 "$(field "$r" '.errors|length')" "no errors on valid artifact"
    assert_equals s1 "$(field "$r" .stage)" "stage echoed in result"
}

test_required_missing() {
    echo "▸ validate_stage_output — required missing"
    mk_schema s2 '{"type":"object","required":["goal","title"],"properties":{}}'
    echo '{"goal":"x"}' > "$TEST_ROOT/b.json"
    local r
    r="$(validate_stage_output s2 "$TEST_ROOT/b.json")"
    assert_equals false "$(field "$r" .valid)" "valid=false when required key missing"
    assert_equals REQUIRED_FIELD_MISSING "$(field "$r" .error_code)" "error_code REQUIRED_FIELD_MISSING"
    assert_equals title "$(field "$r" '.errors[0].field')" "names the missing field"
}

test_type_mismatch() {
    echo "▸ validate_stage_output — type mismatch"
    mk_schema s3 '{"type":"object","properties":{"goal":{"type":"string"}}}'
    echo '{"goal":123}' > "$TEST_ROOT/c.json"
    local r
    r="$(validate_stage_output s3 "$TEST_ROOT/c.json")"
    assert_equals false "$(field "$r" .valid)" "valid=false on type mismatch"
    assert_equals TYPE_MISMATCH "$(field "$r" .error_code)" "error_code TYPE_MISMATCH"
}

test_integer_accepts_number() {
    echo "▸ validate_stage_output — integer accepts number"
    mk_schema s4 '{"type":"object","properties":{"n":{"type":"integer"}}}'
    echo '{"n":7}' > "$TEST_ROOT/d.json"
    local r
    r="$(validate_stage_output s4 "$TEST_ROOT/d.json")"
    assert_equals true "$(field "$r" .valid)" "integer field satisfied by JSON number"
}

test_pattern() {
    echo "▸ validate_stage_output — pattern"
    mk_schema s5 '{"type":"object","properties":{"slug":{"type":"string","pattern":"^[a-z0-9_]+$"}}}'
    echo '{"slug":"good_slug1"}' > "$TEST_ROOT/e.json"
    assert_equals true "$(field "$(validate_stage_output s5 "$TEST_ROOT/e.json")" .valid)" "valid slug matches pattern"
    echo '{"slug":"Bad Slug!"}' > "$TEST_ROOT/e2.json"
    local r
    r="$(validate_stage_output s5 "$TEST_ROOT/e2.json")"
    assert_equals false "$(field "$r" .valid)" "invalid slug fails pattern"
    assert_equals PATTERN_MISMATCH "$(field "$r" .error_code)" "error_code PATTERN_MISMATCH"
}

test_missing_artifact() {
    echo "▸ validate_stage_output — missing artifact"
    mk_schema s6 '{"type":"object","required":["x"]}'
    local r rc
    r="$(validate_stage_output s6 "$TEST_ROOT/does-not-exist.json")"; rc=$?
    assert_exit 0 "$rc" "exit 0 even when artifact missing (not a validator fault)"
    assert_equals false "$(field "$r" .valid)" "valid=false when artifact missing"
    assert_equals ARTIFACT_MISSING "$(field "$r" .error_code)" "error_code ARTIFACT_MISSING"
}

test_unparseable_artifact() {
    echo "▸ validate_stage_output — unparseable JSON artifact"
    mk_schema s7 '{"type":"object"}'
    printf '%s' 'not json{' > "$TEST_ROOT/f.json"
    local r
    r="$(validate_stage_output s7 "$TEST_ROOT/f.json")"
    assert_equals false "$(field "$r" .valid)" "valid=false on unparseable JSON"
    assert_equals ARTIFACT_UNPARSEABLE "$(field "$r" .error_code)" "error_code ARTIFACT_UNPARSEABLE"
}

test_schema_not_found() {
    echo "▸ validate_stage_output — schema not found (backward compatible)"
    echo '{}' > "$TEST_ROOT/g.json"
    local r rc
    r="$(validate_stage_output stage_without_schema "$TEST_ROOT/g.json")"; rc=$?
    assert_exit 0 "$rc" "exit 0 when no schema"
    assert_equals true "$(field "$r" .valid)" "valid=true when no schema (non-breaking)"
    assert_equals SCHEMA_NOT_FOUND "$(field "$r" .error_code)" "error_code SCHEMA_NOT_FOUND"
}

test_invalid_schema_fault() {
    echo "▸ validate_stage_output — invalid schema is a validator fault"
    printf '%s' 'not json{' > "$VALIDATION_SCHEMA_DIR/faulty.schema.json"
    echo '{}' > "$TEST_ROOT/h.json"
    local r rc
    set +e; r="$(validate_stage_output faulty "$TEST_ROOT/h.json")"; rc=$?; set -e
    assert_exit 1 "$rc" "exit 1 on invalid schema (validator fault)"
    assert_equals SCHEMA_INVALID "$(field "$r" .error_code)" "error_code SCHEMA_INVALID"
}

test_markdown_schema() {
    echo "▸ validate_stage_output — markdown/raw-text schema"
    mk_schema md '{"type":"string","minLength":5}'
    printf 'Hello world, this is a plan.' > "$TEST_ROOT/plan.md"
    assert_equals true "$(field "$(validate_stage_output md "$TEST_ROOT/plan.md")" .valid)" "non-empty markdown passes minLength"
    printf 'hi' > "$TEST_ROOT/short.md"
    local r
    r="$(validate_stage_output md "$TEST_ROOT/short.md")"
    assert_equals false "$(field "$r" .valid)" "too-short markdown fails minLength"
    assert_equals TOO_SHORT "$(field "$r" .error_code)" "error_code TOO_SHORT"
}

test_result_shape() {
    echo "▸ validate_stage_output — result shape"
    mk_schema sh '{"type":"object"}'
    echo '{}' > "$TEST_ROOT/i.json"
    local r
    r="$(validate_stage_output sh "$TEST_ROOT/i.json")"
    assert_equals true "$(echo "$r" | jq 'has("valid") and has("stage") and has("errors") and has("warnings") and has("error_code") and has("artifact_size_bytes") and has("validation_time_ms")')" "result has all contract fields"
    assert_equals number "$(echo "$r" | jq -r '.artifact_size_bytes|type')" "artifact_size_bytes is a number"
    assert_equals number "$(echo "$r" | jq -r '.validation_time_ms|type')" "validation_time_ms is a number"
}

# ═══════════════════════════════════════════════════════════════════════════
# UNIT TESTS — format_validation_error & record_validation_metric
# ═══════════════════════════════════════════════════════════════════════════
test_format() {
    echo "▸ format_validation_error"
    local valid='{"valid":true,"stage":"build","errors":[],"warnings":[],"error_code":null,"artifact_size_bytes":10,"validation_time_ms":1}'
    assert_contains "$(format_validation_error "$valid")" "build" "formats a valid result"
    local bad='{"valid":false,"stage":"intake","errors":[{"code":"X","field":"goal","message":"Required field missing: goal"}],"warnings":[],"error_code":"REQUIRED_FIELD_MISSING","artifact_size_bytes":2,"validation_time_ms":1}'
    assert_contains "$(format_validation_error "$bad")" "Required field missing: goal" "formats an error result with detail"
}

test_metric() {
    echo "▸ record_validation_metric"
    : > "$VALIDATION_METRICS_FILE"
    local r='{"valid":false,"stage":"test","errors":[{"code":"X"}],"warnings":[],"error_code":"TYPE_MISMATCH","artifact_size_bytes":3,"validation_time_ms":2}'
    record_validation_metric "$r"
    record_validation_metric "$r"
    local lines
    lines="$(wc -l < "$VALIDATION_METRICS_FILE" | tr -d ' ')"
    assert_equals 2 "$lines" "appends one line per metric (no clobber)"
    assert_equals test "$(tail -1 "$VALIDATION_METRICS_FILE" | jq -r .stage)" "metric line records stage"
    assert_equals TYPE_MISMATCH "$(tail -1 "$VALIDATION_METRICS_FILE" | jq -r .error_code)" "metric line records error_code"
}

# ═══════════════════════════════════════════════════════════════════════════
# INTEGRATION TESTS — CLI
# ═══════════════════════════════════════════════════════════════════════════
test_cli_valid() {
    echo "▸ CLI — valid artifact"
    mk_schema cli '{"type":"object","required":["goal"],"properties":{"goal":{"type":"string"}}}'
    echo '{"goal":"x"}' > "$TEST_ROOT/cli.json"
    local out rc
    set +e; out="$("$CLI" cli "$TEST_ROOT/cli.json" --no-metric 2>&1)"; rc=$?; set -e
    assert_exit 0 "$rc" "CLI exits 0 on valid artifact"
    assert_contains "$out" "valid" "CLI reports valid"
}

test_cli_strict_fail() {
    echo "▸ CLI — strict failure"
    mk_schema clis '{"type":"object","required":["goal"]}'
    echo '{}' > "$TEST_ROOT/clis.json"
    local rc
    set +e; "$CLI" clis "$TEST_ROOT/clis.json" --strict --no-metric >/dev/null 2>&1; rc=$?; set -e
    assert_exit 1 "$rc" "CLI exits 1 in --strict on failure"
}

test_cli_warn_continue() {
    echo "▸ CLI — warn mode continues"
    mk_schema cliw '{"type":"object","required":["goal"]}'
    echo '{}' > "$TEST_ROOT/cliw.json"
    local rc
    set +e; "$CLI" cliw "$TEST_ROOT/cliw.json" --no-metric >/dev/null 2>&1; rc=$?; set -e
    assert_exit 0 "$rc" "CLI exits 0 in warn mode despite failure"
}

test_cli_json() {
    echo "▸ CLI — --json output"
    mk_schema clij '{"type":"object","required":["goal"]}'
    echo '{}' > "$TEST_ROOT/clij.json"
    local out
    out="$("$CLI" clij "$TEST_ROOT/clij.json" --json --no-metric 2>/dev/null)"
    assert_equals false "$(echo "$out" | jq -r .valid)" "--json emits parseable result object"
}

test_cli_usage() {
    echo "▸ CLI — usage errors"
    local rc
    set +e; "$CLI" onlyonearg >/dev/null 2>&1; rc=$?; set -e
    assert_exit 2 "$rc" "CLI exits 2 on missing arguments"
    set +e; "$CLI" --help >/dev/null 2>&1; rc=$?; set -e
    assert_exit 0 "$rc" "CLI --help exits 0"
}

test_cli_lint() {
    echo "▸ CLI — lint subcommand"
    mk_schema lintok '{"type":"object","required":["a"]}'
    local rc
    set +e; "$CLI" lint lintok >/dev/null 2>&1; rc=$?; set -e
    assert_exit 0 "$rc" "CLI lint passes a good schema"
}

test_cli_metric_recorded() {
    echo "▸ CLI — records metric by default"
    : > "$VALIDATION_METRICS_FILE"
    mk_schema clim '{"type":"object"}'
    echo '{}' > "$TEST_ROOT/clim.json"
    "$CLI" clim "$TEST_ROOT/clim.json" >/dev/null 2>&1 || true
    assert_equals 1 "$(wc -l < "$VALIDATION_METRICS_FILE" | tr -d ' ')" "CLI records one metric line by default"
}

# ═══════════════════════════════════════════════════════════════════════════
# INTEGRATION — shipped repo schemas lint clean
# ═══════════════════════════════════════════════════════════════════════════
test_shipped_schemas_lint() {
    echo "▸ shipped config/stage-schemas all lint clean"
    local repo_schemas="$SCRIPT_DIR/../config/stage-schemas"
    local f rc=0 count=0
    for f in "$repo_schemas"/*.schema.json; do
        [[ -f "$f" ]] || continue
        count=$((count+1))
        if ! lint_schema "$f" 2>/dev/null; then rc=1; echo "    lint failed: $f"; fi
    done
    assert_equals 14 "$count" "14 stage schemas shipped"
    assert_exit 0 "$rc" "all shipped schemas lint clean"
}

# ═══════════════════════════════════════════════════════════════════════════
# UNIT TESTS — stage_artifact_path & validate_stage_hook
# ═══════════════════════════════════════════════════════════════════════════
test_stage_artifact_path() {
    echo "▸ stage_artifact_path"
    assert_contains "$(stage_artifact_path intake /a)" "/a/intake.json" "intake → intake.json"
    assert_contains "$(stage_artifact_path plan /a)" "/a/plan.md" "plan → plan.md"
    assert_contains "$(stage_artifact_path spec_generation /a)" "/a/spec.json" "spec_generation → spec.json"
    assert_equals "" "$(stage_artifact_path build /a)" "unmapped stage → empty"
}

test_hook_disabled() {
    echo "▸ validate_stage_hook — disabled / unmapped no-ops"
    local rc
    set +e
    VALIDATION_ENABLED=false validate_stage_hook intake; rc=$?
    set -e
    assert_exit 0 "$rc" "hook no-ops when validation disabled"
    set +e; validate_stage_hook build; rc=$?; set -e
    assert_exit 0 "$rc" "hook no-ops for unmapped stage"
    set +e; VALIDATION_DISABLE_FOR_STAGES="intake plan" validate_stage_hook intake; rc=$?; set -e
    assert_exit 0 "$rc" "hook no-ops when stage in disable list"
}

test_hook_warn_vs_strict() {
    echo "▸ validate_stage_hook — warn vs strict"
    mk_schema intake '{"type":"object","required":["goal"]}'
    local adir="$TEST_ROOT/arts"; mkdir -p "$adir"
    echo '{"nope":1}' > "$adir/intake.json"   # missing required "goal"
    local rc
    set +e; PIPELINE_ARTIFACTS_DIR="$adir" validate_stage_hook intake >/dev/null 2>&1; rc=$?; set -e
    assert_exit 0 "$rc" "warn mode: invalid output does NOT block (exit 0)"
    set +e; PIPELINE_ARTIFACTS_DIR="$adir" VALIDATION_STRICT_MODE=true validate_stage_hook intake >/dev/null 2>&1; rc=$?; set -e
    assert_exit 1 "$rc" "strict mode: invalid output blocks (exit 1)"

    echo '{"goal":"ok"}' > "$adir/intake.json"
    set +e; PIPELINE_ARTIFACTS_DIR="$adir" VALIDATION_STRICT_MODE=true validate_stage_hook intake >/dev/null 2>&1; rc=$?; set -e
    assert_exit 0 "$rc" "strict mode: valid output passes (exit 0)"
}

test_hook_records_metric() {
    echo "▸ validate_stage_hook — records metric"
    mk_schema intake '{"type":"object","required":["goal"]}'
    local adir="$TEST_ROOT/arts2"; mkdir -p "$adir"
    echo '{"goal":"ok"}' > "$adir/intake.json"
    : > "$VALIDATION_METRICS_FILE"
    PIPELINE_ARTIFACTS_DIR="$adir" validate_stage_hook intake >/dev/null 2>&1 || true
    assert_equals 1 "$(wc -l < "$VALIDATION_METRICS_FILE" | tr -d ' ')" "hook records one metric line"
}

test_cfg_resolution() {
    echo "▸ _validation_cfg resolution"
    assert_equals true "$(_validation_cfg validation.enabled VALIDATION_ENABLED true)" "returns default when unset"
    assert_equals false "$(VALIDATION_ENABLED=false _validation_cfg validation.enabled VALIDATION_ENABLED true)" "env var overrides default"
    local cfg="$TEST_ROOT/dc.json"
    echo '{"validation":{"strict_mode":true}}' > "$cfg"
    assert_equals true "$(DAEMON_CONFIG="$cfg" _validation_cfg validation.strict_mode VALIDATION_STRICT_MODE false)" "daemon-config value read"
    assert_equals false "$(DAEMON_CONFIG="$cfg" VALIDATION_STRICT_MODE=false _validation_cfg validation.strict_mode VALIDATION_STRICT_MODE true)" "env overrides daemon-config"
}

# ─── Run ────────────────────────────────────────────────────────────────────
echo ""
echo "═══ Stage Output Validator Test Suite ═══"
echo ""
test_load_schema
test_lint_schema
test_valid_json
test_required_missing
test_type_mismatch
test_integer_accepts_number
test_pattern
test_missing_artifact
test_unparseable_artifact
test_schema_not_found
test_invalid_schema_fault
test_markdown_schema
test_result_shape
test_format
test_metric
test_cli_valid
test_cli_strict_fail
test_cli_warn_continue
test_cli_json
test_cli_usage
test_cli_lint
test_cli_metric_recorded
test_shipped_schemas_lint
test_stage_artifact_path
test_hook_disabled
test_hook_warn_vs_strict
test_hook_records_metric
test_cfg_resolution

echo ""
echo "═══════════════════════════════════════════"
echo "  ${GREEN}PASS: $PASS${RESET}   ${RED}FAIL: $FAIL${RESET}"
echo "═══════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] || exit 1
