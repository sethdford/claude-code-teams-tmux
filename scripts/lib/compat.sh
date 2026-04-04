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
    local file="$1"
    # Linux first (stat -f on Linux shows filesystem info, not file mtime)
    stat -c '%Y' "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo "0"
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
