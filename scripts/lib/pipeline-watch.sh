#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  pipeline-watch.sh — Real-Time Pipeline Progress Stream                     ║
# ║  Live, single-issue progress dashboard. Read-only polling over the          ║
# ║  artifacts the pipeline already writes (pipeline-state.md, progress.md,      ║
# ║  events.jsonl). No new transport, no writes to pipeline state.              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Module guard — prevent double-sourcing
[[ -n "${_PIPELINE_WATCH_LOADED:-}" ]] && return 0
_PIPELINE_WATCH_LOADED=1

# shellcheck disable=SC2034  # VERSION kept for convention/inspection
PIPELINE_WATCH_VERSION="3.3.0"

# Remove a snapshot temp (no-op for the live file).
_watch_rm_snap() {
    [[ "$1" != "$STATE_FILE" ]] && rm -f "$1" 2>/dev/null
    return 0
}

# Refresh cadence (seconds) and stall threshold are config-driven with safe defaults.
WATCH_INTERVAL_DEFAULT="${SW_WATCH_INTERVAL:-5}"
WATCH_STALL_SECONDS_DEFAULT="${SW_WATCH_STALL_SECONDS:-120}"

# ─── Snapshot ──────────────────────────────────────────────────────────────
# write_state() appends to STATE_FILE non-atomically, so a naive read can catch
# a partial frame. Copy to a private temp first, then parse the stable copy.
_watch_snapshot_state() {
    local src="${1:-$STATE_FILE}"
    [[ -f "$src" ]] || return 1
    local snap="${TMPDIR:-/tmp}/sw-watch-snap-$$"
    if cp "$src" "$snap" 2>/dev/null; then
        echo "$snap"
        return 0
    fi
    # Fallback: read the live file directly if cp races a rename.
    echo "$src"
    return 0
}

# ─── Frontmatter field reader ──────────────────────────────────────────────
# Mirrors resume_state() in lib/pipeline-state.sh — single field, quote-stripped.
# The trailing colon in the match disambiguates prefixes (current_stage vs
# current_stage_description).
_watch_read_state_field() {
    local field="$1" file="${2:-$STATE_FILE}"
    [[ -f "$file" ]] || return 1
    local in_fm=false line
    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            if $in_fm; then break; else in_fm=true; continue; fi
        fi
        $in_fm || continue
        case "$line" in
            "$field":*)
                printf '%s' "${line#"$field":}" | sed 's/^ *"\{0,1\}//; s/"\{0,1\} *$//'
                return 0
                ;;
        esac
    done < "$file"
    return 0
}

# ─── Stage progress bar ────────────────────────────────────────────────────
# Input: "intake:complete plan:running build:pending ..." (the stage_progress
# field). Emits per-stage glyphs and a filled block bar with a percentage.
_watch_render_stage_bar() {
    local progress="$1"
    local total=0 done=0 glyphs="" tok sst glyph
    for tok in $progress; do
        sst="${tok#*:}"
        total=$((total + 1))
        case "$sst" in
            complete) done=$((done + 1)); glyph="${GREEN:-}✓${RESET:-}" ;;
            running)  glyph="${CYAN:-}●${RESET:-}" ;;
            failed)   glyph="${RED:-}✗${RESET:-}" ;;
            *)        glyph="${DIM:-}○${RESET:-}" ;;
        esac
        glyphs="${glyphs}${glyph} "
    done
    [[ "$total" -eq 0 ]] && { echo "  (no stages)"; return 0; }

    local pct=$(( done * 100 / total ))
    local width=24
    local filled=$(( done * width / total ))
    [[ "$filled" -gt "$width" ]] && filled="$width"
    local bar="" i
    for (( i = 0; i < filled; i++ )); do bar="${bar}█"; done
    for (( i = filled; i < width; i++ )); do bar="${bar}░"; done

    echo -e "  ${glyphs}"
    echo -e "  ${CYAN:-}${bar}${RESET:-} ${BOLD:-}${pct}%${RESET:-} ${DIM:-}(${done}/${total} stages)${RESET:-}"
}

# ─── Elapsed time (portable) ───────────────────────────────────────────────
_watch_elapsed() {
    local started="$1"
    [[ -z "$started" ]] && { echo "—"; return 0; }
    local start_epoch now
    start_epoch=$(date_to_epoch "$started" 2>/dev/null || echo 0)
    [[ -z "$start_epoch" || "$start_epoch" == "0" ]] && { echo "—"; return 0; }
    now=$(now_epoch 2>/dev/null || date +%s)
    local secs=$(( now - start_epoch ))
    [[ "$secs" -lt 0 ]] && secs=0
    format_duration "$secs"
}

# ─── "Last activity" age from updated_at ───────────────────────────────────
_watch_last_activity() {
    local updated="$1"
    [[ -z "$updated" ]] && { echo "unknown"; return 0; }
    local upd_epoch now
    upd_epoch=$(date_to_epoch "$updated" 2>/dev/null || echo 0)
    [[ -z "$upd_epoch" || "$upd_epoch" == "0" ]] && { echo "$updated"; return 0; }
    now=$(now_epoch 2>/dev/null || date +%s)
    local secs=$(( now - upd_epoch ))
    [[ "$secs" -lt 0 ]] && secs=0
    echo "$(format_duration "$secs") ago"
}

# ─── Build-stage detail panel ──────────────────────────────────────────────
# Parses .claude/loop-logs/progress.md (written by write_progress() each build
# iteration) plus best-effort token usage from costs.json.
_watch_build_panel() {
    local log_dir="${LOG_DIR:-${STATE_DIR:-.claude}/loop-logs}"
    local pf="$log_dir/progress.md"
    [[ -f "$pf" ]] || { echo -e "  ${DIM:-}(build not started — no progress.md yet)${RESET:-}"; return 0; }

    local iter tests restarts
    iter=$(grep -m1 '^- Iteration:' "$pf" 2>/dev/null | sed 's/^- Iteration: *//' || true)
    tests=$(grep -m1 '^- Tests passing:' "$pf" 2>/dev/null | sed 's/^- Tests passing: *//' || true)
    restarts=$(grep -m1 '^- Session restart:' "$pf" 2>/dev/null | sed 's/^- Session restart: *//' || true)

    local test_icon
    case "$tests" in
        true)  test_icon="${GREEN:-}✓ passing${RESET:-}" ;;
        false) test_icon="${RED:-}✗ failing${RESET:-}" ;;
        *)     test_icon="${DIM:-}○ unknown${RESET:-}" ;;
    esac

    [[ -n "$iter" ]]     && echo -e "  ${BOLD:-}Iteration:${RESET:-} ${iter}"
    [[ -n "$restarts" ]] && [[ "$restarts" != "0/0" ]] && echo -e "  ${BOLD:-}Restarts:${RESET:-}  ${restarts}"
    echo -e "  ${BOLD:-}Tests:${RESET:-}     ${test_icon}"

    # Token usage (best-effort; never fails the panel)
    local tokens
    tokens=$(_watch_token_usage)
    [[ -n "$tokens" ]] && echo -e "  ${BOLD:-}Tokens:${RESET:-}    ${tokens}"

    # Recent commits from the progress file's section
    local commits
    commits=$(sed -n '/^## Recent Commits$/,/^## /p' "$pf" 2>/dev/null \
              | grep -vE '^## |^[[:space:]]*$' | head -3 || true)
    if [[ -n "$commits" ]]; then
        echo -e "  ${BOLD:-}Commits:${RESET:-}"
        while IFS= read -r c; do
            [[ -n "$c" ]] && echo -e "    ${DIM:-}${c}${RESET:-}"
        done <<< "$commits"
    fi
}

# ─── Token usage (best-effort) ─────────────────────────────────────────────
_watch_token_usage() {
    local costs="${HOME}/.shipwright/costs.json"
    [[ -f "$costs" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local toks
    toks=$(jq -r '
        ([.entries[]? | (.input_tokens // 0) + (.output_tokens // 0)] | add) // 0
    ' "$costs" 2>/dev/null || echo 0)
    [[ -z "$toks" || "$toks" == "0" || "$toks" == "null" ]] && return 0
    # Humanize large numbers
    if [[ "$toks" -ge 1000000 ]]; then
        printf '%d.%dM tokens' $(( toks / 1000000 )) $(( (toks % 1000000) / 100000 ))
    elif [[ "$toks" -ge 1000 ]]; then
        printf '%dK tokens' $(( toks / 1000 ))
    else
        printf '%d tokens' "$toks"
    fi
}

# ─── Recent activity from events.jsonl ─────────────────────────────────────
_watch_activity() {
    local events_file="${EVENTS_FILE:-$HOME/.shipwright/events.jsonl}"
    [[ -f "$events_file" ]] || { echo -e "  ${DIM:-}(no events)${RESET:-}"; return 0; }
    local n="${1:-5}"
    if command -v jq >/dev/null 2>&1; then
        local lines
        lines=$(tail -40 "$events_file" 2>/dev/null \
            | jq -r 'select(.type != null) | "\(.ts // "")\t\(.type)"' 2>/dev/null \
            | tail -"$n" || true)
        if [[ -n "$lines" ]]; then
            while IFS=$'\t' read -r ts typ; do
                [[ -z "$typ" ]] && continue
                local hms="${ts#*T}"; hms="${hms%Z}"
                echo -e "  ${DIM:-}${hms}${RESET:-} ${typ}"
            done <<< "$lines"
            return 0
        fi
    fi
    # jq-less fallback: raw tail
    tail -"$n" "$events_file" 2>/dev/null | sed 's/^/  /' || true
}

# ─── Advisory completion estimate ──────────────────────────────────────────
# Linear extrapolation from stage fraction and elapsed. Advisory only.
_watch_estimate_completion() {
    local progress="$1" started="$2"
    local total=0 done=0 tok
    for tok in $progress; do
        total=$((total + 1))
        [[ "${tok#*:}" == "complete" ]] && done=$((done + 1))
    done
    [[ "$done" -eq 0 || "$total" -eq 0 ]] && return 0
    [[ "$done" -ge "$total" ]] && return 0

    local start_epoch now
    start_epoch=$(date_to_epoch "$started" 2>/dev/null || echo 0)
    [[ -z "$start_epoch" || "$start_epoch" == "0" ]] && return 0
    now=$(now_epoch 2>/dev/null || date +%s)
    local elapsed=$(( now - start_epoch ))
    [[ "$elapsed" -le 0 ]] && return 0

    # est_total = elapsed * total / done ; remaining = est_total - elapsed
    local est_total=$(( elapsed * total / done ))
    local remaining=$(( est_total - elapsed ))
    [[ "$remaining" -lt 0 ]] && remaining=0
    echo "~$(format_duration "$remaining") remaining (est.)"
}

# ─── Single frame render ───────────────────────────────────────────────────
_watch_render_frame() {
    local snap="$1"
    local p_goal p_status p_stage p_started p_updated p_branch p_issue p_pr p_progress
    p_goal=$(_watch_read_state_field goal "$snap")
    p_status=$(_watch_read_state_field status "$snap")
    p_stage=$(_watch_read_state_field current_stage "$snap")
    p_started=$(_watch_read_state_field started_at "$snap")
    p_updated=$(_watch_read_state_field updated_at "$snap")
    p_branch=$(_watch_read_state_field branch "$snap")
    p_issue=$(_watch_read_state_field issue "$snap")
    p_pr=$(_watch_read_state_field pr_number "$snap")
    p_progress=$(_watch_read_state_field stage_progress "$snap")

    local status_icon
    case "$p_status" in
        running)     status_icon="${CYAN:-}●${RESET:-}" ;;
        complete)    status_icon="${GREEN:-}✓${RESET:-}" ;;
        paused)      status_icon="${YELLOW:-}⏸${RESET:-}" ;;
        interrupted) status_icon="${YELLOW:-}⚡${RESET:-}" ;;
        failed)      status_icon="${RED:-}✗${RESET:-}" ;;
        aborted)     status_icon="${RED:-}◼${RESET:-}" ;;
        *)           status_icon="${DIM:-}○${RESET:-}" ;;
    esac

    echo -e "${PURPLE:-}${BOLD:-}━━━ Pipeline Watch ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET:-}"
    echo ""
    echo -e "  ${BOLD:-}Goal:${RESET:-}     ${p_goal:-—}"
    echo -e "  ${BOLD:-}Status:${RESET:-}   ${status_icon} ${p_status:-unknown}"
    [[ -n "$p_issue" ]]  && echo -e "  ${BOLD:-}Issue:${RESET:-}    ${p_issue}"
    [[ -n "$p_branch" ]] && echo -e "  ${BOLD:-}Branch:${RESET:-}   ${p_branch}"
    [[ -n "$p_pr" ]]     && echo -e "  ${BOLD:-}PR:${RESET:-}       #${p_pr}"
    echo -e "  ${BOLD:-}Stage:${RESET:-}    ${p_stage:-—}"
    echo -e "  ${BOLD:-}Elapsed:${RESET:-}  $(_watch_elapsed "$p_started")"
    echo -e "  ${BOLD:-}Activity:${RESET:-} $(_watch_last_activity "$p_updated")"

    echo ""
    echo -e "  ${BOLD:-}Stages${RESET:-}"
    _watch_render_stage_bar "$p_progress"

    local eta
    eta=$(_watch_estimate_completion "$p_progress" "$p_started")
    [[ -n "$eta" ]] && echo -e "  ${DIM:-}${eta}${RESET:-}"

    if [[ "$p_stage" == "build" ]]; then
        echo ""
        echo -e "  ${BOLD:-}Build${RESET:-}"
        _watch_build_panel
    fi

    echo ""
    echo -e "  ${BOLD:-}Recent Activity${RESET:-}"
    _watch_activity 5

    # Return status via global so the caller's loop can detect terminal state.
    _WATCH_LAST_STATUS="$p_status"
    _WATCH_LAST_UPDATED="$p_updated"
}

# ─── Main loop ─────────────────────────────────────────────────────────────
pipeline_watch() {
    setup_dirs
    LOG_DIR="${LOG_DIR:-$STATE_DIR/loop-logs}"

    if [[ ! -f "$STATE_FILE" ]]; then
        error "No active pipeline to watch."
        echo -e "  Start one: ${DIM:-}shipwright pipeline start --goal \"...\"${RESET:-}"
        echo -e "  Or detached: ${DIM:-}shipwright pipeline start --issue N --detach${RESET:-}"
        return 1
    fi

    local interval="${WATCH_INTERVAL_DEFAULT}"
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=5
    [[ "$interval" -lt 1 ]] && interval=1
    local stall="${WATCH_STALL_SECONDS_DEFAULT}"
    [[ "$stall" =~ ^[0-9]+$ ]] || stall=120

    # One-shot mode for tests / non-interactive snapshots.
    local once=false
    [[ "${SW_WATCH_ONCE:-}" == "1" || "${1:-}" == "--once" ]] && once=true

    local is_tty=false
    [[ -t 1 ]] && is_tty=true

    # Hide cursor and restore it (plus show cursor) on any exit during watch.
    if $is_tty && ! $once; then
        printf '\033[?25l'
        trap '_watch_cleanup_term; return 0' INT TERM
    fi

    local prev_updated="" stall_since=0 frame=0
    while true; do
        frame=$((frame + 1))
        local snap
        snap=$(_watch_snapshot_state "$STATE_FILE") || snap="$STATE_FILE"

        if $is_tty && ! $once; then
            printf '\033[H\033[2J'  # home + clear
        fi

        _watch_render_frame "$snap"

        # Stall detection — updated_at unchanged beyond threshold.
        local now
        now=$(now_epoch 2>/dev/null || date +%s)
        if [[ "$_WATCH_LAST_UPDATED" == "$prev_updated" ]]; then
            [[ "$stall_since" -eq 0 ]] && stall_since="$now"
            local stalled_for=$(( now - stall_since ))
            if [[ "$stall_since" -gt 0 && "$stalled_for" -ge "$stall" ]]; then
                echo ""
                echo -e "  ${YELLOW:-}⚠ No state update in $(format_duration "$stalled_for") — pipeline may be stalled.${RESET:-}"
            fi
        else
            prev_updated="$_WATCH_LAST_UPDATED"
            stall_since=0
        fi

        # Clean exit on terminal state.
        case "$_WATCH_LAST_STATUS" in
            complete|failed|aborted)
                # Remove snapshot temp before exiting.
                _watch_rm_snap "$snap"
                echo ""
                case "$_WATCH_LAST_STATUS" in
                    complete) echo -e "  ${GREEN:-}${BOLD:-}✓ Pipeline complete.${RESET:-}" ;;
                    failed)   echo -e "  ${RED:-}${BOLD:-}✗ Pipeline failed.${RESET:-}" ;;
                    aborted)  echo -e "  ${RED:-}${BOLD:-}◼ Pipeline aborted.${RESET:-}" ;;
                esac
                $is_tty && ! $once && printf '\033[?25h'
                return 0
                ;;
        esac

        _watch_rm_snap "$snap"

        if $once; then
            return 0
        fi

        $is_tty && echo -e "\n  ${DIM:-}Refreshing every ${interval}s · Ctrl-C to exit${RESET:-}"
        sleep "$interval"
    done
}

# Restore terminal state (show cursor) on interrupt.
_watch_cleanup_term() {
    printf '\033[?25h'
    echo ""
}
