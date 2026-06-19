#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-validate-stage-output.sh — Stage Output Schema Validator (CLI)        ║
# ║                                                                          ║
# ║  Validate a pipeline stage's output artifact against its contract schema. ║
# ║  Wraps scripts/lib/validate.sh. Warn-by-default; --strict to fail.        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.3.0"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { :; }

# shellcheck source=lib/validate.sh
source "$SCRIPT_DIR/lib/validate.sh"

show_help() {
    cat <<EOF
USAGE
  shipwright validate-stage-output <stage> <artifact-path> [OPTIONS]
  shipwright validate-stage-output lint [<stage>]

DESCRIPTION
  Validate a pipeline stage output artifact against its contract schema in
  config/stage-schemas/. Checks a documented subset of JSON Schema:
  required[], properties.<f>.type, properties.<f>.pattern, and (for type:string
  schemas) minLength/pattern over raw file content. Unsupported keywords are
  ignored, not enforced.

ARGUMENTS
  <stage>          Pipeline stage name (e.g. intake, spec_generation, plan)
  <artifact-path>  Path to the artifact file produced by that stage

OPTIONS
  --json           Emit the raw result JSON object (machine-readable)
  --strict         Exit non-zero when validation fails (default: warn, exit 0)
  --no-metric      Do not record a metric line
  --help, -h       Show this help
  --version, -v    Show version

SUBCOMMANDS
  lint [<stage>]   Lint one or all stage schemas for unsupported keywords

EXIT CODES
  0   validation ran and passed (or failed in warn mode)
  1   validation failed in --strict mode, OR a validator-internal fault
  2   usage error

EXAMPLES
  shipwright validate-stage-output spec_generation .claude/pipeline-artifacts/spec.json
  shipwright validate-stage-output intake intake.json --strict --json
  shipwright validate-stage-output lint
EOF
}

# ─── lint subcommand ────────────────────────────────────────────────────────
cmd_lint() {
    local only="${1:-}"
    local dir rc=0
    dir="$(validation_schema_dir)"
    if [[ ! -d "$dir" ]]; then
        error "Schema directory not found: $dir"
        return 1
    fi
    local f stage
    for f in "$dir"/*.schema.json; do
        [[ -f "$f" ]] || continue
        stage="$(basename "$f" .schema.json)"
        [[ -n "$only" && "$only" != "$stage" ]] && continue
        if lint_schema "$f" 2>/tmp/lint-err.$$; then
            success "$stage: schema OK"
        else
            error "$stage: schema lint FAILED"
            cat /tmp/lint-err.$$ >&2 2>/dev/null || true
            rc=1
        fi
        rm -f /tmp/lint-err.$$ 2>/dev/null || true
    done
    return $rc
}

main() {
    local json_out=0 strict=0 record=1
    local positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)    show_help; exit 0 ;;
            --version|-v) echo "$VERSION"; exit 0 ;;
            --json)       json_out=1; shift ;;
            --strict)     strict=1; shift ;;
            --no-metric)  record=0; shift ;;
            lint)         shift; cmd_lint "${1:-}"; exit $? ;;
            -*)           error "Unknown option: $1"; show_help; exit 2 ;;
            *)            positional+=("$1"); shift ;;
        esac
    done

    if [[ "${#positional[@]}" -lt 2 ]]; then
        error "Missing arguments: <stage> <artifact-path>"
        show_help
        exit 2
    fi

    local stage="${positional[0]}" artifact="${positional[1]}"

    local result rc
    result="$(validate_stage_output "$stage" "$artifact")"
    rc=$?

    [[ "$record" -eq 1 ]] && record_validation_metric "$result"

    local valid
    valid="$(echo "$result" | jq -r '.valid' 2>/dev/null || echo false)"

    emit_event "validation_result" \
        "stage=$stage" \
        "valid=$valid" \
        "error_code=$(echo "$result" | jq -r '.error_code // "none"')" 2>/dev/null || true

    if [[ "$json_out" -eq 1 ]]; then
        echo "$result"
    else
        format_validation_error "$result"
    fi

    # Validator-internal fault always fails.
    if [[ "$rc" -eq 1 ]]; then
        exit 1
    fi
    # Contract failure: fail only in strict mode.
    if [[ "$valid" != "true" ]]; then
        if [[ "$strict" -eq 1 ]]; then
            exit 1
        fi
        warn "Validation failed but strict mode is off — continuing." >&2
        exit 0
    fi
    exit 0
}

main "$@"
