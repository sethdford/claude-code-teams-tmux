#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright compat — Cross-platform compatibility helpers               ║
# ║  Source this AFTER color definitions for NO_COLOR + platform support    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   source "$SCRIPT_DIR/lib/compat.sh"
#
# Provides:
#   - NO_COLOR / dumb terminal / non-tty detection (auto-blanks color vars)
#   - _to_lower() / _to_upper() — bash 3.2 compat (${var,,}/${var^^} require bash 4+)
#   - file_mtime() — cross-platform file modification time (epoch)
#   - sed_i()    — cross-platform sed in-place editing
#   - open_url() — cross-platform browser open
#   - tmp_dir()  — returns best temp directory for platform
#   - is_wsl()   — detect WSL environment
#   - is_macos() / is_linux() — platform checks
#   - _timeout() — run command with timeout (timeout/gtimeout or no-op on macOS)

# ─── NO_COLOR support (https://no-color.org/) ─────────────────────────────
# Blanks standard color variables when:
#   - NO_COLOR is set (any value)
#   - TERM is "dumb" (e.g. Emacs shell, CI without tty)
#   - stdout is not a terminal (piped output)
if [[ -n "${NO_COLOR:-}" ]] || [[ "${TERM:-}" == "dumb" ]] || { [[ -z "${SHIPWRIGHT_FORCE_COLOR:-}" ]] && [[ ! -t 1 ]]; }; then
    CYAN='' PURPLE='' BLUE='' GREEN='' YELLOW='' RED='' DIM='' BOLD='' RESET=''
    UNDERLINE='' ITALIC=''
fi

# ─── Platform detection ───────────────────────────────────────────────────
_COMPAT_UNAME="${_COMPAT_UNAME:-$(uname -s 2>/dev/null || echo "Unknown")}"

is_macos() { [[ "$_COMPAT_UNAME" == "Darwin" ]]; }
is_linux() { [[ "$_COMPAT_UNAME" == "Linux" ]]; }

# ─── Bash 3.2 compat (macOS ships bash 3.2) ───────────────────────────────
# Case conversion: ${var,,} and ${var^^} require bash 4+. Use these instead:
_to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
_to_upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }
is_wsl()   { is_linux && [[ -n "${WSL_DISTRO_NAME:-}" || -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; }

# ─── sed -i (macOS vs GNU) ────────────────────────────────────────────────
# macOS sed requires '' after -i, GNU sed does not
sed_i() {
    if is_macos; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# ─── Open URL in browser ──────────────────────────────────────────────────
open_url() {
    local url="$1"
    if is_macos; then
        open "$url"
    elif is_wsl; then
        # WSL: use wslview (from wslu) or powershell
        if command -v wslview >/dev/null 2>&1; then
            wslview "$url"
        elif command -v powershell.exe >/dev/null 2>&1; then
            powershell.exe -Command "Start-Process '$url'" 2>/dev/null
        else
            return 1
        fi
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url"
    else
        return 1
    fi
}

# ─── Temp directory (respects Windows %TEMP% and %TMP%) ──────────────────
tmp_dir() {
    echo "${TMPDIR:-${TEMP:-${TMP:-/tmp}}}"
}

# ─── Process existence check (portable) ──────────────────────────────────
pid_exists() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

# ─── Shared Error Taxonomy ───────────────────────────────────────────────
# Canonical error categories used by sw-pipeline.sh, sw-memory.sh, and others.
# Extend via ~/.shipwright/optimization/error-taxonomy.json
SW_ERROR_CATEGORIES="test_failure build_error lint_error timeout dependency flaky config security permission unknown"

sw_valid_error_category() {
    local category="${1:-}"
    local custom_file="$HOME/.shipwright/optimization/error-taxonomy.json"
    # Check custom taxonomy first
    if [[ -f "$custom_file" ]] && command -v jq >/dev/null 2>&1; then
        local custom_cats
        custom_cats=$(jq -r '.categories[]? // empty' "$custom_file" 2>/dev/null || true)
        if [[ -n "$custom_cats" ]]; then
            local cat_item
            while IFS= read -r cat_item; do
                if [[ "$cat_item" == "$category" ]]; then
                    return 0
                fi
            done <<< "$custom_cats"
        fi
    fi
    # Check built-in categories
    local builtin
    for builtin in $SW_ERROR_CATEGORIES; do
        if [[ "$builtin" == "$category" ]]; then
            return 0
        fi
    done
    return 1
}

# ─── Complexity Bucketing ────────────────────────────────────────────────
# Shared by sw-intelligence.sh and sw-self-optimize.sh.
# Thresholds tunable via ~/.shipwright/optimization/complexity-clusters.json
complexity_bucket() {
    local complexity="${1:-5}"
    local config_file="$HOME/.shipwright/optimization/complexity-clusters.json"
    local low_boundary=3
    local high_boundary=6
    if [[ -f "$config_file" ]] && command -v jq >/dev/null 2>&1; then
        local lb hb
        lb=$(jq -r '.low_boundary // 3' "$config_file" 2>/dev/null || echo "3")
        hb=$(jq -r '.high_boundary // 6' "$config_file" 2>/dev/null || echo "6")
        [[ "$lb" =~ ^[0-9]+$ ]] && low_boundary="$lb"
        [[ "$hb" =~ ^[0-9]+$ ]] && high_boundary="$hb"
    fi
    if [[ "$complexity" -le "$low_boundary" ]]; then
        echo "low"
    elif [[ "$complexity" -le "$high_boundary" ]]; then
        echo "medium"
    else
        echo "high"
    fi
}

# ─── Framework / Language Detection ──────────────────────────────────────
# Shared by sw-prep.sh and sw-pipeline.sh.
detect_primary_language() {
    local dir="${1:-.}"
    if [[ -f "$dir/package.json" ]]; then
        if [[ -f "$dir/tsconfig.json" ]]; then
            echo "typescript"
        else
            echo "javascript"
        fi
    elif [[ -f "$dir/requirements.txt" || -f "$dir/pyproject.toml" || -f "$dir/setup.py" ]]; then
        echo "python"
    elif [[ -f "$dir/go.mod" ]]; then
        echo "go"
    elif [[ -f "$dir/Cargo.toml" ]]; then
        echo "rust"
    elif [[ -f "$dir/build.gradle" || -f "$dir/pom.xml" ]]; then
        echo "java"
    elif [[ -f "$dir/mix.exs" ]]; then
        echo "elixir"
    else
        echo "unknown"
    fi
}

detect_test_framework() {
    local dir="${1:-.}"
    if [[ -f "$dir/package.json" ]] && command -v jq >/dev/null 2>&1; then
        local runner
        runner=$(jq -r '
            if .devDependencies.vitest then "vitest"
            elif .devDependencies.jest then "jest"
            elif .devDependencies.mocha then "mocha"
            elif .devDependencies.ava then "ava"
            elif .devDependencies.tap then "tap"
            else ""
            end' "$dir/package.json" 2>/dev/null || echo "")
        if [[ -n "$runner" ]]; then
            echo "$runner"
            return 0
        fi
    fi
    if [[ -f "$dir/pytest.ini" || -f "$dir/pyproject.toml" ]]; then
        echo "pytest"
    elif [[ -f "$dir/go.mod" ]]; then
        echo "go test"
    elif [[ -f "$dir/Cargo.toml" ]]; then
        echo "cargo test"
    elif [[ -f "$dir/build.gradle" ]]; then
        echo "gradle test"
    else
        echo ""
    fi
}

# ─── Cross-platform file modification time (epoch) ────────────────────────
# macOS/BSD: stat -f %m; Linux: stat -c '%Y'
file_mtime() {
    local file="$1" m=""
    # GNU first: `-c '%Y'` is GNU-only and BSD-only `-f '%m'` is mutually exclusive,
    # so this is safe cross-platform. Capturing into a var (not chaining raw output)
    # prevents a failed attempt's stdout from leaking into the substitution — on Linux,
    # `stat -f %m` is parsed as `--file-system` and prints fs info to stdout on failure.
    m=$(stat -c '%Y' "$file" 2>/dev/null) || m=$(stat -f '%m' "$file" 2>/dev/null) || m=""
    case "$m" in
        ''|*[!0-9]*) echo "0" ;;
        *) echo "$m" ;;
    esac
}

# ─── Timeout command (macOS may lack timeout; gtimeout from coreutils) ─────
# Usage: _timeout <seconds> <command> [args...]
_timeout() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    else
        # Fallback: run without timeout (e.g. on older macOS)
        "$@"
    fi
}

# ─── Cross-platform date helpers (GNU date -d vs BSD date -j/-v) ──────────
# date_to_epoch: convert date string to Unix epoch
# date_days_ago: YYYY-MM-DD for N days ago
# date_add_days: YYYY-MM-DD for base_date + N days
# epoch_to_iso: convert epoch to ISO 8601
date_to_epoch() {
    local datestr="$1"
    local fmt=""
    if [[ "$datestr" == *"T"* ]]; then
        fmt="%Y-%m-%dT%H:%M:%SZ"
    else
        fmt="%Y-%m-%d"
    fi
    if date -u -d "$datestr" +%s 2>/dev/null; then
        return
    fi
    # BSD date: -j = don't set date, -f = format
    date -u -j -f "$fmt" "$datestr" +%s 2>/dev/null || echo "0"
}

date_days_ago() {
    local days="$1"
    if date -u -d "$days days ago" +%Y-%m-%d 2>/dev/null; then
        return
    fi
    date -u -v-${days}d +%Y-%m-%d 2>/dev/null || echo "1970-01-01"
}

date_add_days() {
    local base_date="$1"
    local days="$2"
    if date -u -d "${base_date} + ${days} days" +%Y-%m-%d 2>/dev/null; then
        return
    fi
    # BSD: compute via epoch arithmetic
    local base_epoch
    base_epoch=$(date_to_epoch "$base_date")
    if [[ -n "$base_epoch" && "$base_epoch" != "0" ]]; then
        local result_epoch=$((base_epoch + (days * 86400)))
        date -u -r "$result_epoch" +%Y-%m-%d 2>/dev/null || date -u -d "@$result_epoch" +%Y-%m-%d 2>/dev/null || echo "1970-01-01"
    else
        echo "1970-01-01"
    fi
}

epoch_to_iso() {
    local epoch="$1"
    date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    python3 -c "import datetime; print(datetime.datetime.utcfromtimestamp($epoch).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null || \
    echo "1970-01-01T00:00:00Z"
}

# ─── Cross-platform MD5 ──────────────────────────────────────────────────
# Usage:
#   compute_md5 --string "some text"   → md5 hash of string
#   compute_md5 /path/to/file          → md5 hash of file
compute_md5() {
    if [[ "${1:-}" == "--string" ]]; then
        shift
        printf '%s' "$1" | md5 2>/dev/null || printf '%s' "$1" | md5sum 2>/dev/null | cut -d' ' -f1
    else
        # File mode
        local file="$1"
        md5 -q "$file" 2>/dev/null || md5sum "$file" 2>/dev/null | awk '{print $1}'
    fi
}

# ─── Intelligent Model Selection ──────────────────────────────────────────
# _smart_model <purpose> [default]
# Returns model name from config chain: env var → daemon-config.json → default
# Purpose: "classification", "detection", "validation", "commit_quality",
#          "default", or any custom key under model_routing.{purpose}
_smart_model() {
    local purpose="${1:-default}" default="${2:-haiku}"

    # Sanitize purpose to alphanumeric/underscore only (prevents eval injection)
    if [[ ! "$purpose" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        echo "$default"
        return
    fi

    # 1. Environment override (e.g., SW_MODEL_CLASSIFICATION=sonnet)
    local env_key
    env_key="SW_MODEL_$(echo "$purpose" | tr '[:lower:]' '[:upper:]')"
    local env_val=""
    eval 'env_val="${'"$env_key"':-}"' 2>/dev/null || true
    if [[ -n "$env_val" ]]; then
        echo "$env_val"
        return
    fi

    # 2. Daemon config: model_routing.{purpose}
    local cfg="${DAEMON_CONFIG:-${WORK_DIR:-.}/.claude/daemon-config.json}"
    if [[ -f "$cfg" ]]; then
        local cfg_val
        cfg_val=$(jq -r --arg p "$purpose" '.model_routing[$p] // empty' "$cfg" 2>/dev/null || true)
        if [[ -n "$cfg_val" && "$cfg_val" != "null" ]]; then
            echo "$cfg_val"
            return
        fi
    fi

    # 3. User-level config: ~/.shipwright/model-routing.json
    local user_cfg="${HOME}/.shipwright/model-routing.json"
    if [[ -f "$user_cfg" ]]; then
        local user_val
        user_val=$(jq -r --arg p "$purpose" '.[$p] // empty' "$user_cfg" 2>/dev/null || true)
        if [[ -n "$user_val" && "$user_val" != "null" ]]; then
            echo "$user_val"
            return
        fi
    fi

    # 4. Default
    echo "$default"
}

# _smart_int <config_key> <default>
# Read int from daemon-config with env override and default fallback
_smart_int() {
    local key="$1" default="$2"

    # Sanitize key to alphanumeric/underscore/dot only (prevents eval injection)
    if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_.]*$ ]]; then
        echo "$default"
        return
    fi

    # Env override: config.key.path → SW_KEY_PATH
    local env_key
    env_key="SW_$(echo "$key" | tr '[:lower:].' '[:upper:]_')"
    local env_val=""
    eval 'env_val="${'"$env_key"':-}"' 2>/dev/null || true
    if [[ -n "$env_val" ]]; then
        echo "$env_val"
        return
    fi

    # Daemon config
    local cfg="${DAEMON_CONFIG:-${WORK_DIR:-.}/.claude/daemon-config.json}"
    if [[ -f "$cfg" ]]; then
        local cfg_val
        cfg_val=$(jq -r --arg k "$key" 'getpath($k | split(".")) // empty' "$cfg" 2>/dev/null || true)
        if [[ -n "$cfg_val" && "$cfg_val" != "null" ]]; then
            echo "$cfg_val"
            return
        fi
    fi

    echo "$default"
}

# _smart_effort <stage>
# Read effort level from config, with per-stage defaults
_smart_effort() {
    local stage="$1"

    # 1. Explicit override
    if [[ -n "${EFFORT_LEVEL_OVERRIDE:-}" ]]; then
        echo "$EFFORT_LEVEL_OVERRIDE"
        return
    fi

    # 2. Config: effort_levels.{stage}
    local cfg="${DAEMON_CONFIG:-${WORK_DIR:-.}/.claude/daemon-config.json}"
    if [[ -f "$cfg" ]]; then
        local cfg_val
        cfg_val=$(jq -r --arg s "$stage" '.effort_levels[$s] // empty' "$cfg" 2>/dev/null || true)
        if [[ -n "$cfg_val" && "$cfg_val" != "null" ]]; then
            echo "$cfg_val"
            return
        fi
    fi

    # 3. Intelligent defaults (same as before, but now overridable)
    case "$stage" in
        intake)              echo "low" ;;
        plan|design)         echo "high" ;;
        build|test)          echo "medium" ;;
        review|compound_quality) echo "high" ;;
        pr|merge)            echo "low" ;;
        deploy|validate|monitor) echo "medium" ;;
        *)                   echo "medium" ;;
    esac
}

# _exponential_backoff <attempt> [base_seconds] [max_seconds]
# Returns sleep duration with jitter for retry loops
_exponential_backoff() {
    local attempt="${1:-1}" base="${2:-2}" max="${3:-60}"
    local delay=$base
    local i=1
    while [ "$i" -lt "$attempt" ]; do
        delay=$((delay * 2))
        i=$((i + 1))
    done
    # Cap at max
    [ "$delay" -gt "$max" ] && delay=$max
    # Add jitter: ±25%
    local jitter=$(( (RANDOM % (delay / 2 + 1)) - delay / 4 ))
    delay=$((delay + jitter))
    [ "$delay" -lt 1 ] && delay=1
    echo "$delay"
}
