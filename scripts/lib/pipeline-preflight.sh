#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  pipeline-preflight.sh — Pipeline Pre-Flight Health Validator             ║
# ║                                                                          ║
# ║  Broad environment health checks run BEFORE a pipeline launches. Blocks  ║
# ║  start (with actionable fixes) when the environment is unhealthy.        ║
# ║                                                                          ║
# ║  Checks: disk space, tmux availability, network connectivity, GitHub     ║
# ║  API rate limits, Claude CLI auth. Complements (does not replace) the    ║
# ║  basic preflight_checks() in pipeline-util.sh.                           ║
# ║                                                                          ║
# ║  Testability: each check delegates raw environment probing to a small    ║
# ║  overridable getter (_preflight_disk_free_kb, _preflight_has_tmux, …) so  ║
# ║  tests mock by redefining the getter, never by touching real system      ║
# ║  state or calling real APIs.                                             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Load guard — safe to source multiple times.
[[ -n "${_PIPELINE_PREFLIGHT_LOADED:-}" ]] && return 0
_PIPELINE_PREFLIGHT_LOADED=1

# ─── Color fallbacks (when sourced without helpers.sh) ──────────────────────
: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${DIM:=}" "${RESET:=}" "${BOLD:=}" "${PURPLE:=}"

# Config helper fallback (when sourced without config.sh)
[[ "$(type -t _config_get_int 2>/dev/null)" == "function" ]] || _config_get_int() { echo "${2:-0}"; }

# Accumulated blocking-failure reasons for the most recent run.
PREFLIGHT_REASONS=()

# ─── Output helpers (respect PREFLIGHT_QUIET for --json mode) ────────────────
_preflight_say() { [[ "${PREFLIGHT_QUIET:-false}" == "true" ]] || echo -e "$1"; }
_preflight_ok()   { _preflight_say "  ${GREEN}✓${RESET} $2"; }
_preflight_warn() { _preflight_say "  ${YELLOW}⚠${RESET} $2"; }
_preflight_skip() { _preflight_say "  ${DIM}○${RESET} $2"; }
_preflight_fail() {
    local check="$1" msg="$2"
    PREFLIGHT_REASONS+=("${check}: ${msg}")
    _preflight_say "  ${RED}✗${RESET} $msg"
}

# ─── Overridable environment probes (mock these in tests) ───────────────────
_preflight_disk_free_kb() {
    # Free space in KB for the project root (cross-platform `df -k`).
    df -k "${PROJECT_ROOT:-.}" 2>/dev/null | tail -1 | awk '{print $4}'
}
_preflight_has_tmux()     { command -v tmux >/dev/null 2>&1; }
_preflight_has_curl()     { command -v curl >/dev/null 2>&1; }
_preflight_has_gh()       { command -v gh >/dev/null 2>&1; }
_preflight_claude_ok()    { command -v claude >/dev/null 2>&1; }
_preflight_network_ok() {
    local t
    t=$(_config_get_int "network.connect_timeout" 5 2>/dev/null || echo 5)
    [[ "$t" =~ ^[0-9]+$ ]] || t=5
    curl -sf --connect-timeout "$t" -o /dev/null "https://api.github.com" 2>/dev/null
}
_preflight_github_rate_json() {
    gh api rate_limit 2>/dev/null
}

# ─── Check 1: Disk space (fast, blocking) ───────────────────────────────────
check_disk_space() {
    local min_gb free_kb min_kb
    min_gb=$(_config_get_int "preflight.min_disk_gb" 5 2>/dev/null || echo 5)
    [[ "$min_gb" =~ ^[0-9]+$ ]] || min_gb=5

    free_kb=$(_preflight_disk_free_kb)
    if ! [[ "$free_kb" =~ ^[0-9]+$ ]]; then
        _preflight_warn "disk_space" "Could not determine free disk space (skipping)"
        return 0
    fi

    min_kb=$(( min_gb * 1024 * 1024 ))
    if [[ "$free_kb" -lt "$min_kb" ]]; then
        _preflight_fail "disk_space" \
            "Low disk space: $(( free_kb / 1024 ))MB free (need ${min_gb}GB). Fix: free up disk or lower preflight.min_disk_gb in daemon-config.json."
        return 1
    fi
    _preflight_ok "disk_space" "Disk space OK ($(( free_kb / 1024 / 1024 ))GB free, need ${min_gb}GB)"
    return 0
}

# ─── Check 2: tmux availability (fast, warn-only) ───────────────────────────
check_tmux() {
    if _preflight_has_tmux; then
        _preflight_ok "tmux" "tmux available"
        return 0
    fi
    _preflight_warn "tmux" \
        "tmux not found — team sessions and detached pipelines unavailable. Fix: install tmux (brew install tmux / apt install tmux)."
    return 0
}

# ─── Check 3: Network connectivity (network, blocking) ──────────────────────
check_network() {
    if [[ "${NO_GITHUB:-false}" == "true" || "${SHIPWRIGHT_LOCAL:-0}" == "1" || "${OFFLINE:-false}" == "true" ]]; then
        _preflight_skip "network" "Network check skipped (offline/local mode)"
        return 0
    fi
    if ! _preflight_has_curl; then
        _preflight_warn "network" "curl not available — skipping network check"
        return 0
    fi
    if _preflight_network_ok; then
        _preflight_ok "network" "Network connectivity OK"
        return 0
    fi
    _preflight_fail "network" \
        "No network connectivity to github.com. Fix: check your internet connection, or run with --local for offline mode."
    return 1
}

# ─── Check 4: GitHub API rate limit (network, blocking, fail-open) ──────────
check_github_rate_limit() {
    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        _preflight_skip "github_rate_limit" "GitHub rate limit check skipped (--no-github/--local)"
        return 0
    fi
    if ! _preflight_has_gh; then
        _preflight_warn "github_rate_limit" "gh CLI not available — skipping rate limit check"
        return 0
    fi

    local rate_json
    rate_json=$(_preflight_github_rate_json)
    if [[ -z "$rate_json" ]]; then
        _preflight_warn "github_rate_limit" "Could not query GitHub rate limit (fail-open)"
        return 0
    fi

    local remaining limit reset
    remaining=$(echo "$rate_json" | jq -r '.resources.core.remaining // .rate.remaining // empty' 2>/dev/null)
    limit=$(echo "$rate_json"     | jq -r '.resources.core.limit // .rate.limit // empty' 2>/dev/null)
    reset=$(echo "$rate_json"     | jq -r '.resources.core.reset // .rate.reset // empty' 2>/dev/null)

    if ! [[ "$remaining" =~ ^[0-9]+$ ]]; then
        _preflight_warn "github_rate_limit" "Unexpected rate limit response (fail-open)"
        return 0
    fi

    local threshold
    threshold=$(_config_get_int "preflight.min_github_requests" 10 2>/dev/null || echo 10)
    [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=10

    if [[ "$remaining" -lt "$threshold" ]]; then
        local mins="unknown"
        if [[ "$reset" =~ ^[0-9]+$ ]]; then
            local now diff
            now=$(date +%s)
            diff=$(( (reset - now + 59) / 60 ))
            [[ "$diff" -lt 0 ]] && diff=0
            mins="$diff"
        fi
        _preflight_fail "github_rate_limit" \
            "GitHub API rate limited: ${remaining}/${limit:-?} requests remaining, retry in ${mins} minutes. Fix: wait or use --skip-preflight."
        return 1
    fi
    _preflight_ok "github_rate_limit" "GitHub rate limit OK (${remaining}/${limit:-?} remaining)"
    return 0
}

# ─── Check 5: Claude CLI auth (slowest, blocking) ───────────────────────────
check_claude_auth() {
    if _preflight_claude_ok; then
        _preflight_ok "claude_auth" "Claude CLI available"
        return 0
    fi
    _preflight_fail "claude_auth" \
        "Claude CLI not found — plan/build stages will fail. Fix: install Claude CLI and run 'claude login'."
    return 1
}

# ─── Orchestrator ───────────────────────────────────────────────────────────
# preflight_health_check
#   Runs all checks in fast→network→auth order, collecting blocking failures.
#   Network/rate-limit checks are skipped when connectivity is already down.
#   Emits preflight.failed (with reasons) or preflight.passed to events.jsonl.
#   Returns 0 if healthy, 1 if any blocking failure.
preflight_health_check() {
    PREFLIGHT_REASONS=()
    local blocking=0

    _preflight_say "${PURPLE}${BOLD}━━━ Pre-flight Health Validation ━━━${RESET}"
    _preflight_say ""

    # 1. Fast checks first — no I/O delay.
    check_disk_space || blocking=$(( blocking + 1 ))
    check_tmux || true

    # 2. Network checks — skip downstream GitHub checks if connectivity is down.
    local network_up=true
    if ! check_network; then
        network_up=false
        blocking=$(( blocking + 1 ))
    fi
    if [[ "$network_up" == "true" ]]; then
        check_github_rate_limit || blocking=$(( blocking + 1 ))
    else
        _preflight_skip "github_rate_limit" "GitHub rate limit check skipped (no network)"
    fi

    # 3. Auth check last — slowest.
    check_claude_auth || blocking=$(( blocking + 1 ))

    _preflight_say ""

    if [[ "$blocking" -gt 0 ]]; then
        local reasons=""
        [[ ${#PREFLIGHT_REASONS[@]} -gt 0 ]] && reasons="${PREFLIGHT_REASONS[*]}"
        if type emit_event >/dev/null 2>&1; then
            emit_event "preflight.failed" \
                "count=$blocking" \
                "reasons=$reasons" \
                "skip_flag_used=${SKIP_PREFLIGHT:-false}"
        fi
        _preflight_say "${RED}${BOLD}✗ Pre-flight health check failed: ${blocking} blocking issue(s)${RESET}"
        return 1
    fi

    if type emit_event >/dev/null 2>&1; then
        emit_event "preflight.passed" "skip_flag_used=${SKIP_PREFLIGHT:-false}"
    fi
    _preflight_say "${GREEN}${BOLD}✓ Pre-flight health check passed${RESET}"
    return 0
}
