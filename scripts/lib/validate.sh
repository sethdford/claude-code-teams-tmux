#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  lib/validate.sh — Stage Output Schema Validator & Contract Enforcement   ║
# ║                                                                          ║
# ║  jq-based "contract subset" validator for pipeline stage artifacts.       ║
# ║  Validates a DOCUMENTED SUBSET of JSON Schema draft 2020-12:               ║
# ║    • required[]                — top-level key presence                    ║
# ║    • properties.<f>.type       — single primitive type check              ║
# ║    • properties.<f>.pattern    — anchored regex on string fields          ║
# ║    • top-level type:string     — treat artifact as raw text (markdown)    ║
# ║      with minLength / pattern checks against the whole file               ║
# ║  Everything else (nested $ref, oneOf, allOf, type arrays) is IGNORED,     ║
# ║  not failed. See .claude/CLAUDE.md "Adding a New Stage Output Schema".     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VALIDATE_LIB_VERSION="3.3.0"

# Guard against double-sourcing.
if [[ -n "${_SW_VALIDATE_LIB_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_SW_VALIDATE_LIB_LOADED=1

# ─── Resolve the schema directory (env → repo default) ──────────────────────
_validate_lib_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }

# Returns the directory holding <stage>.schema.json files.
validation_schema_dir() {
    if [[ -n "${VALIDATION_SCHEMA_DIR:-}" ]]; then
        echo "$VALIDATION_SCHEMA_DIR"
        return
    fi
    # Repo root is two levels up from scripts/lib/
    local lib_dir repo_root
    lib_dir="$(_validate_lib_dir)"
    repo_root="$(cd "$lib_dir/../.." && pwd)"
    echo "$repo_root/config/stage-schemas"
}

# Metrics file (overridable for tests).
validation_metrics_file() {
    echo "${VALIDATION_METRICS_FILE:-${HOME}/.shipwright/validation-metrics.jsonl}"
}

# ─── Millisecond clock (portable: GNU date nanoseconds → fallback seconds) ──
_validate_now_ms() {
    local n
    n="$(date +%s%N 2>/dev/null || true)"
    # macOS / BSD date returns the literal "%N" or "...N"; detect and fall back.
    if [[ -z "$n" || "$n" == *N* ]]; then
        echo $(( $(date +%s) * 1000 ))
    else
        echo $(( n / 1000000 ))
    fi
}

# ─── load_schema <stage> ────────────────────────────────────────────────────
# Echoes the resolved schema path on stdout. Exit 0 if found, 1 if not found.
load_schema() {
    local stage="$1"
    local dir
    dir="$(validation_schema_dir)"
    local path="$dir/$stage.schema.json"
    if [[ -f "$path" ]]; then
        echo "$path"
        return 0
    fi
    return 1
}

# ─── lint_schema <schema_path> ──────────────────────────────────────────────
# Verifies a schema is parseable JSON and does not lean on UNSUPPORTED keywords
# in a load-bearing way (which would silently over-promise enforcement).
# Exit 0 = OK. Exit 1 = invalid/unsupported. Diagnostics on stderr.
lint_schema() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "lint: schema not found: $path" >&2
        return 1
    fi
    if ! jq -e . "$path" >/dev/null 2>&1; then
        echo "lint: schema is not valid JSON: $path" >&2
        return 1
    fi
    # Reject load-bearing unsupported composition keywords at the top level or
    # inside properties — these are silently ignored by the validator, so their
    # presence means the author expects enforcement that does not happen.
    local unsupported
    unsupported="$(jq -r '
        [ paths | .[] | select(type=="string")
          | select(IN("$ref","oneOf","allOf","anyOf","not","if","then","else","patternProperties")) ]
        | unique | .[]' "$path" 2>/dev/null || true)"
    if [[ -n "$unsupported" ]]; then
        echo "lint: schema uses unsupported keyword(s) that will NOT be enforced:" >&2
        echo "$unsupported" | sed 's/^/  - /' >&2
        return 1
    fi
    return 0
}

# ─── _validate_contract <schema_path> <artifact_path> ───────────────────────
# Core jq subset check. Emits a JSON array of error objects on stdout.
# Returns 0 on a completed check (even with errors), non-zero on jq fault.
_validate_contract() {
    local schema="$1" artifact="$2"
    local top_type
    top_type="$(jq -r '.type // "object"' "$schema" 2>/dev/null || echo object)"

    if [[ "$top_type" == "string" ]]; then
        # Raw-text artifact (e.g. markdown): check minLength / pattern on content.
        jq -Rs --slurpfile schema "$schema" '
            . as $content
            | ($schema[0]) as $s
            | ( [ ($s.minLength // 0) as $min
                  | select(($content | length) < $min)
                  | {code:"TOO_SHORT", field:"<content>",
                     message:("Artifact shorter than minLength \($min) (got \($content|length))")} ]
              + [ ($s.pattern // empty) as $pat
                  | select(($content | test($pat)) | not)
                  | {code:"PATTERN_MISMATCH", field:"<content>",
                     message:("Artifact content does not match pattern \($pat)")} ] )
        ' "$artifact" 2>/dev/null
        return $?
    fi

    # JSON artifact: required keys, primitive types, string patterns.
    jq --slurpfile schema "$schema" '
        ($schema[0]) as $s
        | ($s.required // []) as $req
        | ($s.properties // {}) as $props
        | . as $doc
        | ( [ $req[] as $k
              | select(($doc | has($k)) | not)
              | {code:"REQUIRED_FIELD_MISSING", field:$k,
                 message:("Required field missing: \($k)")} ]
          + [ $props | to_entries[]
              | .key as $f | .value as $spec
              | select(($spec.type | type) == "string")
              | select($doc | has($f))
              | { f:$f, want:$spec.type, got:($doc[$f] | type) }
              | select(
                  ( (.want == "number"  and .got == "number")
                  or (.want == "integer" and .got == "number")
                  or (.want != "number" and .want != "integer" and .got == .want) )
                  | not )
              | {code:"TYPE_MISMATCH", field:.f,
                 message:("Field \(.f): expected \(.want), got \(.got)")} ]
          + [ $props | to_entries[]
              | .key as $f | .value as $spec
              | select(($spec.pattern | type) == "string")
              | select($doc | has($f))
              | select(($doc[$f] | type) == "string")
              | select(($doc[$f] | test($spec.pattern)) | not)
              | {code:"PATTERN_MISMATCH", field:$f,
                 message:("Field \($f): does not match pattern \($spec.pattern)")} ] )
    ' "$artifact" 2>/dev/null
    return $?
}

# ─── validate_stage_output <stage> <artifact_path> ──────────────────────────
# Emits a result JSON object on stdout. Exit 0 = validation ran (pass OR fail);
# Exit 1 = validator-internal fault (unreadable/invalid schema, jq crash, timeout).
validate_stage_output() {
    local stage="$1" artifact="${2:-}"
    local start_ms end_ms elapsed_ms
    start_ms="$(_validate_now_ms)"
    local timeout_s="${VALIDATION_TIMEOUT:-30}"

    _emit_result() {
        # _emit_result <valid> <errors_json> <error_code> [artifact_size]
        local valid="$1" errors="$2" code="${3:-}" size="${4:-0}"
        end_ms="$(_validate_now_ms)"
        elapsed_ms=$(( end_ms - start_ms ))
        [[ "$elapsed_ms" -lt 0 ]] && elapsed_ms=0
        jq -n -c \
            --arg stage "$stage" \
            --argjson valid "$valid" \
            --argjson errors "$errors" \
            --arg code "$code" \
            --argjson size "$size" \
            --argjson ms "$elapsed_ms" \
            '{valid:$valid, stage:$stage, errors:$errors, warnings:[],
              error_code:(if $code=="" then null else $code end),
              artifact_size_bytes:$size, validation_time_ms:$ms}'
    }

    # Resolve schema. Missing schema → valid=true (backward compatible).
    local schema
    if ! schema="$(load_schema "$stage")"; then
        _emit_result true '[]' "SCHEMA_NOT_FOUND"
        return 0
    fi

    # Schema must lint clean, else it's a validator fault.
    if ! lint_schema "$schema" 2>/dev/null; then
        _emit_result false '[{"code":"SCHEMA_INVALID","field":"<schema>","message":"Schema is unparseable or uses unsupported keywords"}]' "SCHEMA_INVALID"
        return 1
    fi

    # Artifact must exist.
    if [[ -z "$artifact" || ! -f "$artifact" ]]; then
        _emit_result false "$(jq -n -c --arg a "$artifact" '[{code:"ARTIFACT_MISSING", field:"<artifact>", message:("Artifact not found: \($a)")}]')" "ARTIFACT_MISSING"
        return 0
    fi

    local size
    size="$(wc -c < "$artifact" 2>/dev/null | tr -d ' ')"
    [[ -z "$size" ]] && size=0

    # For JSON-typed schemas the artifact must be parseable JSON.
    local top_type
    top_type="$(jq -r '.type // "object"' "$schema" 2>/dev/null || echo object)"
    if [[ "$top_type" != "string" ]]; then
        if ! jq -e . "$artifact" >/dev/null 2>&1; then
            _emit_result false '[{"code":"ARTIFACT_UNPARSEABLE","field":"<artifact>","message":"Artifact is not valid JSON"}]' "ARTIFACT_UNPARSEABLE" "$size"
            return 0
        fi
    fi

    # Run the contract check under a timeout (bounds catastrophic regex / huge files).
    local errors rc
    if command -v timeout >/dev/null 2>&1; then
        errors="$(timeout "$timeout_s" bash -c '
            source "$1"; _validate_contract "$2" "$3"' _ "${BASH_SOURCE[0]}" "$schema" "$artifact")"
        rc=$?
    else
        errors="$(_validate_contract "$schema" "$artifact")"
        rc=$?
    fi

    if [[ "$rc" -eq 124 ]]; then
        _emit_result false '[{"code":"VALIDATION_TIMEOUT","field":"<artifact>","message":"Validation exceeded timeout"}]' "VALIDATION_TIMEOUT" "$size"
        return 1
    fi
    if [[ "$rc" -ne 0 || -z "$errors" ]]; then
        # jq fault, or empty output where an array was expected.
        if [[ -z "$errors" ]]; then errors='[]'; fi
        if [[ "$rc" -ne 0 ]]; then
            _emit_result false '[{"code":"SCHEMA_INVALID","field":"<validator>","message":"Validator faulted while checking artifact"}]' "SCHEMA_INVALID" "$size"
            return 1
        fi
    fi

    local err_count
    err_count="$(echo "$errors" | jq 'length' 2>/dev/null || echo 0)"
    if [[ "$err_count" -gt 0 ]]; then
        local first_code
        first_code="$(echo "$errors" | jq -r '.[0].code // "VALIDATION_FAILED"' 2>/dev/null || echo VALIDATION_FAILED)"
        _emit_result false "$errors" "$first_code" "$size"
        return 0
    fi

    _emit_result true '[]' "" "$size"
    return 0
}

# ─── format_validation_error <result_json> ──────────────────────────────────
# Human-readable rendering of a result object (for CLI default output).
format_validation_error() {
    local result="$1"
    echo "$result" | jq -r '
        if .valid then
            "✓ \(.stage): output valid (\(.artifact_size_bytes) bytes, \(.validation_time_ms)ms)"
        else
            "✗ \(.stage): output FAILED validation"
            + (if .error_code then "  [\(.error_code)]" else "" end)
            + "\n"
            + ( [ .errors[] | "  • \(.field): \(.message)" ] | join("\n") )
        end'
}

# ─── record_validation_metric <result_json> ─────────────────────────────────
# Appends one JSON line to the metrics file. Atomic-append; never blocks pipeline.
record_validation_metric() {
    local result="$1"
    local file
    file="$(validation_metrics_file)"
    mkdir -p "$(dirname "$file")" 2>/dev/null || true

    local line
    line="$(echo "$result" | jq -c \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{ts:$ts, stage:.stage, valid:.valid, error_code:.error_code,
          error_count:(.errors|length), validation_time_ms:.validation_time_ms,
          artifact_size_bytes:.artifact_size_bytes}' 2>/dev/null || true)"
    [[ -z "$line" ]] && return 0

    if command -v flock >/dev/null 2>&1; then
        local lock="$file.lock"
        (
            flock -x 9 2>/dev/null || true
            printf '%s\n' "$line" >> "$file"
        ) 9>"$lock" 2>/dev/null || printf '%s\n' "$line" >> "$file" 2>/dev/null || true
    else
        # Single-line printf append is atomic up to PIPE_BUF on Linux/macOS.
        printf '%s\n' "$line" >> "$file" 2>/dev/null || true
    fi
    return 0
}

# ─── Config resolution (env → daemon-config.json → default) ─────────────────
# _validation_cfg <config.key> <ENV_VAR> <default>
_validation_cfg() {
    local cfgkey="$1" envvar="$2" default="$3"
    local v=""
    eval 'v="${'"$envvar"':-}"' 2>/dev/null || true
    if [[ -n "$v" ]]; then echo "$v"; return; fi
    local cfg="${DAEMON_CONFIG:-${WORK_DIR:-.}/.claude/daemon-config.json}"
    if [[ -f "$cfg" ]]; then
        local cv
        cv="$(jq -r --arg k "$cfgkey" 'getpath($k | split(".")) // empty' "$cfg" 2>/dev/null || true)"
        if [[ -n "$cv" && "$cv" != "null" ]]; then echo "$cv"; return; fi
    fi
    echo "$default"
}

# ─── stage_artifact_path <stage> [artifacts_dir] ────────────────────────────
# Maps a stage to its canonical output artifact. Echoes the path, or empty
# for stages with no single validated artifact (those are skipped by the hook).
stage_artifact_path() {
    local stage="$1"
    local dir="${2:-${PIPELINE_ARTIFACTS_DIR:-${WORK_DIR:-.}/.claude/pipeline-artifacts}}"
    case "$stage" in
        intake)          echo "$dir/intake.json" ;;
        plan)            echo "$dir/plan.md" ;;
        design)          echo "$dir/design.md" ;;
        spec_generation) echo "$dir/spec.json" ;;
        *)               echo "" ;;
    esac
}

# ─── validate_stage_hook <stage> ────────────────────────────────────────────
# Post-stage validation hook for the pipeline. Non-breaking by default:
#   • validation.enabled=false (or VALIDATION_ENABLED=false) → no-op
#   • stage in validation.disable_for_stages → no-op
#   • no artifact mapping or no schema → no-op (backward compatible)
#   • invalid + strict_mode=true → return 1 (caller blocks pipeline)
#   • invalid + warn (default) → emit warning, return 0
# Returns 1 ONLY when strict mode is on AND a real contract failure occurred.
validate_stage_hook() {
    local stage="$1"

    [[ "$(_validation_cfg validation.enabled VALIDATION_ENABLED true)" == "false" ]] && return 0

    local disabled
    disabled="$(_validation_cfg validation.disable_for_stages VALIDATION_DISABLE_FOR_STAGES "")"
    case " ${disabled//,/ } " in *" $stage "*) return 0 ;; esac

    local artifact
    artifact="$(stage_artifact_path "$stage")"
    [[ -z "$artifact" ]] && return 0

    # No schema for this stage → nothing to enforce (non-breaking).
    load_schema "$stage" >/dev/null 2>&1 || return 0

    local result valid
    result="$(validate_stage_output "$stage" "$artifact" 2>/dev/null || true)"
    [[ -z "$result" ]] && return 0
    record_validation_metric "$result" 2>/dev/null || true
    valid="$(echo "$result" | jq -r '.valid' 2>/dev/null || echo true)"

    if type emit_event >/dev/null 2>&1; then
        emit_event "validation_result" \
            "stage=$stage" \
            "valid=$valid" \
            "error_code=$(echo "$result" | jq -r '.error_code // "none"' 2>/dev/null || echo none)" 2>/dev/null || true
    fi

    [[ "$valid" == "true" ]] && return 0

    local msg
    msg="$(format_validation_error "$result" 2>/dev/null || true)"
    if [[ "$(_validation_cfg validation.strict_mode VALIDATION_STRICT_MODE false)" == "true" ]]; then
        if type error >/dev/null 2>&1; then
            error "Stage output validation FAILED for '$stage' (strict mode):"
        else
            echo "Stage output validation FAILED for '$stage' (strict mode):" >&2
        fi
        echo "$msg" >&2
        return 1
    fi
    if type warn >/dev/null 2>&1; then
        warn "Stage output validation issues for '$stage' (non-blocking):"
    else
        echo "Stage output validation issues for '$stage' (non-blocking):" >&2
    fi
    echo "$msg" >&2
    return 0
}
