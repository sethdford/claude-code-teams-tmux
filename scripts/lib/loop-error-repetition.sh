#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  loop-error-repetition.sh                                                  ║
# ║  Build Loop Error Repetition Detector with Auto-Escalation                ║
# ║                                                                           ║
# ║  Detects when the SAME error recurs across build-loop iterations (using a ║
# ║  normalized, stable signature) and drives a graduated auto-escalation     ║
# ║  ladder: inject targeted hint → bump effort → escalate model → restart    ║
# ║  session → abort and flag for human.                                      ║
# ║                                                                           ║
# ║  Bash 3.2 compatible. Degrades gracefully without jq. Additive and        ║
# ║  observability-first — emits events; escalation is config-gated.          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Public API:
#   ler_normalize_signature <error_text>       -> "<category>:<hash>" (pure)
#   ler_current_signature                        -> signature for current failure
#   ler_record_and_count <signature>             -> echoes consecutive repeat count
#   ler_decide_escalation <count> <current_rung> -> echoes "<action>:<detail>:<new_rung>"
#   ler_run                                      -> orchestrator; exports LER_ACTION/DETAIL/RUNG
#
# shellcheck disable=SC2034
VERSION="3.3.0"

# Module guard (repo convention)
[[ -n "${_MODULE_LOOP_ERROR_REPETITION_LOADED:-}" ]] && return 0
_MODULE_LOOP_ERROR_REPETITION_LOADED=1

# ─── Fallback shims (when sourced standalone / deps absent) ──────────────────
# emit_event: no-op if the host loop has not defined it.
type emit_event >/dev/null 2>&1 || emit_event() { :; }

# ─── Signature Normalization ─────────────────────────────────────────────────
# ler_normalize_signature <error_text>
#
# Produces a STABLE fingerprint so the same underlying error yields the same
# signature across iterations even when volatile tokens (line numbers, hex
# addresses, timestamps, PIDs, tmp paths, iteration numbers) differ.
# Output: "<category>:<hash>". Empty input -> empty output (no failure).
ler_normalize_signature() {
    local error_text="${1:-}"
    [[ -z "$error_text" ]] && { echo ""; return 0; }

    # Classify BEFORE stripping (category derives from semantic content).
    local category
    if type recovery_classify_error >/dev/null 2>&1; then
        category=$(recovery_classify_error "$error_text" 2>/dev/null || echo "unknown")
    elif type erract_classify >/dev/null 2>&1; then
        category=$(erract_classify "$error_text" 2>/dev/null || echo "unknown")
    else
        category="unknown"
    fi
    [[ -z "$category" ]] && category="unknown"

    # Normalize the text into a stable canonical form.
    # bash 3.2 safe: use tr/sed only, never ${var,,}.
    local normalized
    normalized=$(printf '%s\n' "$error_text" \
        | sed -e 's/\x1b\[[0-9;]*m//g' \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E \
            -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[t ][0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?z?/TS/g' \
            -e 's/[0-9]{2}:[0-9]{2}:[0-9]{2}/TS/g' \
            -e 's/0x[0-9a-f]+/0xADDR/g' \
            -e 's#/tmp/[a-z0-9._/-]+#/tmp/P#g' \
            -e 's#/var/folders/[a-z0-9._/-]+#/tmp/P#g' \
            -e 's/iteration[ _-]?[0-9]+/iteration-N/g' \
            -e 's/:[0-9]+/:N/g' \
            -e 's/line [0-9]+/line N/g' \
            -e 's/\bpid[ =:]?[0-9]+/pidN/g' \
            -e 's/\b[0-9]+\b/N/g' \
        | tr -s '[:space:]' ' ' \
        | sed -E 's/^ +//; s/ +$//' \
        | head -3)

    # Collapse the (up to 3) canonical lines into one string and hash it.
    local joined
    joined=$(printf '%s ' $normalized 2>/dev/null)
    joined=$(printf '%s' "$joined" | sed -E 's/ +$//')

    local hash
    if command -v md5sum >/dev/null 2>&1; then
        hash=$(printf '%s' "$joined" | md5sum 2>/dev/null | cut -c1-8)
    elif command -v md5 >/dev/null 2>&1; then
        hash=$(printf '%s' "$joined" | md5 2>/dev/null | cut -c1-8)
    else
        # cksum is POSIX and always available; stable across runs.
        hash=$(printf '%s' "$joined" | cksum 2>/dev/null | cut -d' ' -f1)
    fi
    [[ -z "$hash" ]] && hash="0"

    echo "${category}:${hash}"
}

# ─── Current-Failure Signature ───────────────────────────────────────────────
# ler_current_signature
#
# Derives the normalized signature for the CURRENT iteration's failure from
# $LOG_DIR/error-summary.json (written by write_error_summary). Falls back to
# the tail of the test/build log. Echoes empty string on success / no failure
# (the caller treats empty as "reset the ladder").
ler_current_signature() {
    local log_dir="${LOG_DIR:-.}"
    local summary="$log_dir/error-summary.json"
    local error_text=""

    if [[ -f "$summary" ]]; then
        if command -v jq >/dev/null 2>&1; then
            error_text=$(jq -r '(.error_lines // []) | join("\n")' "$summary" 2>/dev/null || true)
            # If error_lines was empty but a nonzero error_count exists (jq-less
            # producer path), fall through to the log-tail fallback below.
        fi
        if [[ -z "$error_text" ]]; then
            # jq absent or empty error_lines: scrape raw lines from the JSON.
            error_text=$(grep -oE '"error_lines"[^]]*\]' "$summary" 2>/dev/null \
                | tr ',' '\n' | grep -oE '"[^"]+"' | tr -d '"' \
                | grep -viE '^error_lines$' || true)
        fi
    fi

    # Fallback: tail of the most recent test/build log for this iteration.
    if [[ -z "$error_text" ]]; then
        local it="${ITERATION:-0}"
        local candidate
        for candidate in \
            "${TEST_LOG_FILE:-}" \
            "$log_dir/tests-iter-${it}.log" \
            "$log_dir/iteration-${it}.log"; do
            [[ -n "$candidate" && -f "$candidate" ]] || continue
            error_text=$(tail -30 "$candidate" 2>/dev/null \
                | grep -iE '(error|fail|assert|exception|panic)' | head -10 || true)
            [[ -n "$error_text" ]] && break
        done
    fi

    [[ -z "$error_text" ]] && { echo ""; return 0; }
    ler_normalize_signature "$error_text"
}

# ─── State: Record & Count Consecutive Repeats ───────────────────────────────
# ler_record_and_count <signature>
#
# Atomically updates $LOG_DIR/error-repetition-state.json and echoes the new
# consecutive repeat count.
#   same signature as last   -> repeat_count++
#   different signature       -> reset to 1, rung 0
#   empty signature (success) -> reset to 0, rung 0
# Corrupt/unreadable state is treated as a fresh start.
ler_record_and_count() {
    local signature="${1:-}"
    local log_dir="${LOG_DIR:-.}"
    local state="$log_dir/error-repetition-state.json"
    mkdir -p "$log_dir" 2>/dev/null || true

    # Load previous state.
    local prev_sig="" prev_count=0 prev_rung=0 first_seen="${ITERATION:-0}"
    if [[ -f "$state" ]]; then
        if command -v jq >/dev/null 2>&1; then
            prev_sig=$(jq -r '.signature // ""' "$state" 2>/dev/null || echo "")
            prev_count=$(jq -r '.repeat_count // 0' "$state" 2>/dev/null || echo 0)
            prev_rung=$(jq -r '.escalation_rung // 0' "$state" 2>/dev/null || echo 0)
            first_seen=$(jq -r '.first_seen_iteration // 0' "$state" 2>/dev/null || echo 0)
        else
            prev_sig=$(grep -oE '"signature"[[:space:]]*:[[:space:]]*"[^"]*"' "$state" 2>/dev/null | sed -E 's/.*:"([^"]*)"/\1/' || echo "")
            prev_count=$(grep -oE '"repeat_count"[[:space:]]*:[[:space:]]*[0-9]+' "$state" 2>/dev/null | grep -oE '[0-9]+$' || echo 0)
            prev_rung=$(grep -oE '"escalation_rung"[[:space:]]*:[[:space:]]*[0-9]+' "$state" 2>/dev/null | grep -oE '[0-9]+$' || echo 0)
            first_seen=$(grep -oE '"first_seen_iteration"[[:space:]]*:[[:space:]]*[0-9]+' "$state" 2>/dev/null | grep -oE '[0-9]+$' || echo 0)
        fi
    fi
    # Sanitize numerics (corrupt state -> 0).
    [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
    [[ "$prev_rung" =~ ^[0-9]+$ ]] || prev_rung=0
    [[ "$first_seen" =~ ^[0-9]+$ ]] || first_seen="${ITERATION:-0}"

    # Compute new count / rung.
    local new_count new_rung
    if [[ -z "$signature" ]]; then
        new_count=0; new_rung=0; first_seen="${ITERATION:-0}"
    elif [[ "$signature" == "$prev_sig" ]]; then
        new_count=$(( prev_count + 1 )); new_rung="$prev_rung"
    else
        new_count=1; new_rung=0; first_seen="${ITERATION:-0}"
    fi

    # Atomic write (tmp + mv, repo convention).
    local tmp="${state}.tmp.$$"
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg sig "$signature" \
            --argjson count "$new_count" \
            --argjson rung "$new_rung" \
            --argjson first "${first_seen:-0}" \
            --argjson iter "${ITERATION:-0}" \
            '{signature:$sig,repeat_count:$count,escalation_rung:$rung,first_seen_iteration:$first,last_iteration:$iter}' \
            > "$tmp" 2>/dev/null && mv "$tmp" "$state" || rm -f "$tmp" 2>/dev/null
    else
        # jq-absent plain-text fallback (still valid JSON).
        local esc_sig
        esc_sig=$(printf '%s' "$signature" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '{"signature":"%s","repeat_count":%s,"escalation_rung":%s,"first_seen_iteration":%s,"last_iteration":%s}\n' \
            "$esc_sig" "$new_count" "$new_rung" "${first_seen:-0}" "${ITERATION:-0}" \
            > "$tmp" 2>/dev/null && mv "$tmp" "$state" || rm -f "$tmp" 2>/dev/null
    fi

    echo "$new_count"
}

# ─── Persist a newly-applied escalation rung ─────────────────────────────────
# _ler_update_rung <new_rung>  (internal) — rewrites escalation_rung in state.
_ler_update_rung() {
    local new_rung="${1:-0}"
    local log_dir="${LOG_DIR:-.}"
    local state="$log_dir/error-repetition-state.json"
    [[ -f "$state" ]] || return 0
    local tmp="${state}.tmp.$$"
    if command -v jq >/dev/null 2>&1; then
        jq --argjson rung "$new_rung" '.escalation_rung=$rung' "$state" > "$tmp" 2>/dev/null \
            && mv "$tmp" "$state" || rm -f "$tmp" 2>/dev/null
    else
        sed -E "s/(\"escalation_rung\"[[:space:]]*:[[:space:]]*)[0-9]+/\1${new_rung}/" "$state" > "$tmp" 2>/dev/null \
            && mv "$tmp" "$state" || rm -f "$tmp" 2>/dev/null
    fi
}

# ─── Hint lookup for a signature's category ──────────────────────────────────
# _ler_hint_for_signature <signature> — echoes a targeted retry hint.
_ler_hint_for_signature() {
    local signature="${1:-}"
    local category="${signature%%:*}"
    [[ -z "$category" || "$category" == "$signature" ]] && category="unknown"

    local hint=""
    if type recovery_get_strategy >/dev/null 2>&1; then
        local strategy_raw
        strategy_raw=$(recovery_get_strategy "$category" 2>/dev/null || true)
        # strategy_raw is "<strategy>:<human hint>"; keep the hint portion.
        hint="${strategy_raw#*:}"
    fi
    [[ -z "$hint" ]] && hint="This exact error has recurred across iterations. Stop repeating the previous approach — diagnose the root cause and try a FUNDAMENTALLY DIFFERENT fix."
    echo "$hint"
}

# ─── Escalation Ladder ───────────────────────────────────────────────────────
# ler_decide_escalation <repeat_count> <current_rung> <signature>
#
# Echoes "<action>:<detail>:<new_rung>". Advances at most one rung per call and
# only when repeat_count >= threshold AND the rung has not yet been applied.
# Each rung is config-gated. Action "none" means no escalation this iteration.
ler_decide_escalation() {
    local count="${1:-0}"
    local current_rung="${2:-0}"
    local signature="${3:-}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    [[ "$current_rung" =~ ^[0-9]+$ ]] || current_rung=0

    local threshold max_rung
    threshold=$(_ler_int "loop.error_repetition.threshold" 3)
    max_rung=$(_ler_int "loop.error_repetition.max_rung" 4)

    # Below threshold: no escalation.
    if [[ "$count" -lt "$threshold" ]]; then
        echo "none::${current_rung}"
        return 0
    fi

    # Toggles (default on).
    local allow_model allow_restart allow_abort
    allow_model=$(_ler_bool "loop.error_repetition.allow_model_escalation" true)
    allow_restart=$(_ler_bool "loop.error_repetition.allow_restart" true)
    allow_abort=$(_ler_bool "loop.error_repetition.allow_abort" true)

    # Walk from the current rung to the first applicable, enabled rung (<= max_rung).
    local rung="$current_rung"
    while [[ "$rung" -le "$max_rung" ]]; do
        case "$rung" in
            0)
                local hint
                hint=$(_ler_hint_for_signature "$signature")
                echo "inject_hint:${hint}:1"
                return 0
                ;;
            1)
                echo "bump_effort:high:2"
                return 0
                ;;
            2)
                if [[ "$allow_model" == "true" ]]; then
                    local target="${FALLBACK_MODEL:-}"
                    [[ -z "$target" ]] && target="opus"
                    echo "escalate_model:${target}:3"
                    return 0
                fi
                rung=$(( rung + 1 ))
                ;;
            3)
                if [[ "$allow_restart" == "true" ]]; then
                    echo "restart_session:same error repeated ${count}x — restarting session for fresh context:4"
                    return 0
                fi
                rung=$(( rung + 1 ))
                ;;
            *)
                if [[ "$allow_abort" == "true" ]]; then
                    echo "abort:same error repeated ${count}x — flagging for human intervention:$(( max_rung + 1 ))"
                    return 0
                fi
                echo "none::${current_rung}"
                return 0
                ;;
        esac
    done

    echo "none::${current_rung}"
}

# ─── Orchestrator ────────────────────────────────────────────────────────────
# ler_run
#
# Runs once per iteration after write_error_summary. Computes the current
# signature, records the repeat count, emits observability events, decides the
# next escalation action, and exports directives for sw-loop.sh to apply:
#   LER_ACTION  — none|inject_hint|bump_effort|escalate_model|restart_session|abort
#   LER_DETAIL  — action-specific payload (hint text / model / effort / message)
#   LER_RUNG    — the escalation rung after this decision
#   LER_COUNT   — current consecutive repeat count
#   LER_SIGNATURE — the normalized signature (empty on success)
ler_run() {
    export LER_ACTION="none" LER_DETAIL="" LER_RUNG=0 LER_COUNT=0 LER_SIGNATURE=""

    # Feature gate.
    if [[ "$(_ler_bool "loop.error_repetition.enabled" true)" != "true" ]]; then
        return 0
    fi

    local signature
    signature=$(ler_current_signature)
    LER_SIGNATURE="$signature"

    local count
    count=$(ler_record_and_count "$signature")
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    LER_COUNT="$count"

    # No active failure -> ladder already reset; nothing to escalate.
    [[ -z "$signature" ]] && return 0

    local threshold
    threshold=$(_ler_int "loop.error_repetition.threshold" 3)

    # Read the rung we're currently at (post-record).
    local current_rung
    current_rung=$(_ler_state_field "escalation_rung" 0)

    # Emit detection event once the streak crosses the threshold.
    if [[ "$count" -ge "$threshold" ]]; then
        local category="${signature%%:*}"
        emit_event "loop.error_repetition_detected" \
            "count=$count" \
            "threshold=$threshold" \
            "signature=$signature" \
            "category=$category" \
            "iteration=${ITERATION:-0}" \
            "job_id=${PIPELINE_JOB_ID:-loop-$$}"
    fi

    # Decide escalation.
    local decision action detail new_rung
    decision=$(ler_decide_escalation "$count" "$current_rung" "$signature")
    action="${decision%%:*}"
    local rest="${decision#*:}"
    detail="${rest%:*}"
    new_rung="${rest##*:}"
    [[ "$new_rung" =~ ^[0-9]+$ ]] || new_rung="$current_rung"

    LER_ACTION="$action"
    LER_DETAIL="$detail"
    LER_RUNG="$new_rung"

    if [[ "$action" != "none" ]]; then
        _ler_update_rung "$new_rung"
        emit_event "loop.error_escalation" \
            "action=$action" \
            "rung=$new_rung" \
            "count=$count" \
            "category=${signature%%:*}" \
            "iteration=${ITERATION:-0}" \
            "job_id=${PIPELINE_JOB_ID:-loop-$$}"
    fi

    return 0
}

# ─── Config helpers (wrap _smart_int / add a bool variant) ───────────────────
_ler_int() {
    local key="$1" default="$2"
    if type _smart_int >/dev/null 2>&1; then
        _smart_int "$key" "$default"
    else
        echo "$default"
    fi
}

_ler_bool() {
    local key="$1" default="$2"
    local val=""
    # Env override: key.path -> SW_KEY_PATH
    local env_key
    env_key="SW_$(printf '%s' "$key" | tr '[:lower:].' '[:upper:]_')"
    eval 'val="${'"$env_key"':-}"' 2>/dev/null || true
    if [[ -z "$val" ]]; then
        local cfg="${DAEMON_CONFIG:-${WORK_DIR:-.}/.claude/daemon-config.json}"
        if [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1; then
            val=$(jq -r --arg k "$key" 'getpath($k | split(".")) // empty' "$cfg" 2>/dev/null || true)
        fi
    fi
    [[ -z "$val" || "$val" == "null" ]] && val="$default"
    case "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on) echo "true" ;;
        *) echo "false" ;;
    esac
}

# _ler_state_field <field> <default> — read a numeric field from the state file.
_ler_state_field() {
    local field="$1" default="${2:-0}"
    local log_dir="${LOG_DIR:-.}"
    local state="$log_dir/error-repetition-state.json"
    [[ -f "$state" ]] || { echo "$default"; return 0; }
    local val=""
    if command -v jq >/dev/null 2>&1; then
        val=$(jq -r --arg f "$field" '.[$f] // empty' "$state" 2>/dev/null || echo "")
    else
        val=$(grep -oE "\"$field\"[[:space:]]*:[[:space:]]*[0-9]+" "$state" 2>/dev/null | grep -oE '[0-9]+$' || echo "")
    fi
    [[ "$val" =~ ^[0-9]+$ ]] || val="$default"
    echo "$val"
}
