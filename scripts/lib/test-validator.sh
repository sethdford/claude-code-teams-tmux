#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#   Test Command Validator — Preflight check before build loop starts
#   Validates test command works, attempts auto-repair for common issues
# ═══════════════════════════════════════════════════════════════════════════

VERSION="1.0.0"

[[ -n "${_SW_TEST_VALIDATOR_LOADED:-}" ]] && return 0
_SW_TEST_VALIDATOR_LOADED=1

# ─── Defaults ────────────────────────────────────────────────────────────
TEST_VALIDATOR_TIMEOUT=10
TEST_VALIDATOR_ENABLED="${SW_PREFLIGHT_ENABLED:-true}"
VALIDATOR_CACHE_DIR="${VALIDATOR_CACHE_DIR:-./.claude/pipeline-artifacts}"

# ─── Probe the test command with a short timeout ───────────────────────
_probe_test_cmd() {
    local cmd="$1"
    local probe_method="${2:-help}"  # help, list, or version
    local output
    local exit_code

    # For help/version, use --help or --version
    case "$probe_method" in
        help)
            # Try common help flags
            output=$(timeout "$TEST_VALIDATOR_TIMEOUT" bash -c "$cmd --help" 2>&1 || true)
            if [[ -z "$output" ]]; then
                output="PROBE_FAILED"
            fi
            ;;
        list)
            # For test runners that have a --list or --collect-only
            output=$(timeout "$TEST_VALIDATOR_TIMEOUT" bash -c "$cmd --list" 2>&1 || true)
            if [[ -z "$output" ]]; then
                output=$(timeout "$TEST_VALIDATOR_TIMEOUT" bash -c "$cmd --collect-only" 2>&1 || true)
            fi
            if [[ -z "$output" ]]; then
                output="PROBE_FAILED"
            fi
            ;;
        version)
            output=$(timeout "$TEST_VALIDATOR_TIMEOUT" bash -c "$cmd --version" 2>&1 || true)
            if [[ -z "$output" ]]; then
                output="PROBE_FAILED"
            fi
            ;;
        *)
            output=$(timeout "$TEST_VALIDATOR_TIMEOUT" bash -c "$cmd --help" 2>&1 || true)
            if [[ -z "$output" ]]; then
                output="PROBE_FAILED"
            fi
            ;;
    esac

    echo "$output"
}

# ─── Classify test command failure from stderr/stdout ──────────────────
classify_test_cmd_failure() {
    local output="$1"

    # Check for probe failure marker
    if [[ "$output" == "PROBE_FAILED" ]]; then
        echo "unknown"
        return 0
    fi

    # Class 2: Module/package not found (Node.js specific) - CHECK FIRST
    if grep -qiE 'cannot find module|MODULE_NOT_FOUND|ERR_MODULE_NOT_FOUND' <<< "$output"; then
        echo "missing_dependencies"
        return 0
    fi

    # Class 1: Command not found
    if grep -qiE 'command not found|no such file|ENOENT' <<< "$output"; then
        echo "command_not_found"
        return 0
    fi

    # Class 3: Permission denied
    if grep -qiE 'permission denied|eacces' <<< "$output"; then
        echo "permission_error"
        return 0
    fi

    # Class 4: Syntax error in test file
    if grep -qiE 'syntax error|SyntaxError|parse error' <<< "$output"; then
        echo "syntax_error"
        return 0
    fi

    # Class 5: Timeout/hang
    if [[ "$output" == "124" ]] || grep -q "timed out" <<< "$output"; then
        echo "timeout"
        return 0
    fi

    # Class 6: Other runtime errors
    if grep -qiE 'error|failed|exception' <<< "$output"; then
        echo "runtime_error"
        return 0
    fi

    # No error detected
    echo "unknown"
    return 0
}

# ─── Detect project type and package manager ───────────────────────────
_detect_project_info() {
    local pkg_manager=""
    local project_type=""

    # Check for Node.js project
    if [[ -f "package.json" ]]; then
        project_type="node"
        if [[ -f "yarn.lock" ]]; then
            pkg_manager="yarn"
        elif [[ -f "pnpm-lock.yaml" ]]; then
            pkg_manager="pnpm"
        else
            pkg_manager="npm"
        fi
    # Check for Python project
    elif [[ -f "pyproject.toml" ]] || [[ -f "requirements.txt" ]]; then
        project_type="python"
        if [[ -f "pyproject.toml" ]]; then
            pkg_manager="poetry"
        else
            pkg_manager="pip"
        fi
    # Check for Ruby project
    elif [[ -f "Gemfile" ]]; then
        project_type="ruby"
        pkg_manager="bundle"
    # Check for Go project
    elif [[ -f "go.mod" ]]; then
        project_type="go"
        pkg_manager="go"
    # Check for Rust project
    elif [[ -f "Cargo.toml" ]]; then
        project_type="rust"
        pkg_manager="cargo"
    fi

    echo "$project_type:$pkg_manager"
}

# ─── Attempt auto-repair based on failure class ──────────────────────
attempt_auto_repair() {
    local failure_class="$1"
    local project_info="$2"
    local repair_output=""

    local project_type="${project_info%%:*}"
    local pkg_manager="${project_info##*:}"

    case "$failure_class" in
        command_not_found)
            # Check if command exists in node_modules/.bin
            if [[ -d "node_modules/.bin" ]]; then
                export PATH="$(pwd)/node_modules/.bin:$PATH"
                return 0
            fi
            return 1
            ;;
        missing_dependencies)
            # Install dependencies based on project type
            case "$pkg_manager" in
                npm)
                    if command -v npm >/dev/null 2>&1; then
                        repair_output=$(npm install 2>&1 || true)
                        return 0
                    fi
                    ;;
                yarn)
                    if command -v yarn >/dev/null 2>&1; then
                        repair_output=$(yarn install 2>&1 || true)
                        return 0
                    fi
                    ;;
                pnpm)
                    if command -v pnpm >/dev/null 2>&1; then
                        repair_output=$(pnpm install 2>&1 || true)
                        return 0
                    fi
                    ;;
                pip)
                    if command -v pip >/dev/null 2>&1; then
                        repair_output=$(pip install -r requirements.txt 2>&1 || true)
                        return 0
                    fi
                    ;;
                poetry)
                    if command -v poetry >/dev/null 2>&1; then
                        repair_output=$(poetry install 2>&1 || true)
                        return 0
                    fi
                    ;;
                bundle)
                    if command -v bundle >/dev/null 2>&1; then
                        repair_output=$(bundle install 2>&1 || true)
                        return 0
                    fi
                    ;;
                go)
                    if command -v go >/dev/null 2>&1; then
                        repair_output=$(go mod download 2>&1 || true)
                        return 0
                    fi
                    ;;
                cargo)
                    if command -v cargo >/dev/null 2>&1; then
                        repair_output=$(cargo fetch 2>&1 || true)
                        return 0
                    fi
                    ;;
            esac
            return 1
            ;;
        permission_error)
            # Try to fix permission errors
            if [[ -f "package.json" ]] && command -v npm >/dev/null 2>&1; then
                repair_output=$(npm install 2>&1 || true)
                return 0
            fi
            return 1
            ;;
        syntax_error|timeout)
            # These cannot be auto-repaired
            return 1
            ;;
        runtime_error|unknown)
            # Try a general dependency install
            case "$pkg_manager" in
                npm)
                    if command -v npm >/dev/null 2>&1; then
                        repair_output=$(npm install 2>&1 || true)
                        return 0
                    fi
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
    esac

    return 1
}

# ─── Write validation report atomically ─────────────────────────────────
write_validation_report() {
    local status="$1"
    local test_cmd="$2"
    local error_msg="${3:-}"
    local repairs_attempted="${4:-}"
    local diagnostics="${5:-}"

    mkdir -p "$VALIDATOR_CACHE_DIR"

    local report_file="$VALIDATOR_CACHE_DIR/test-validation.json"
    local tmp_report="$report_file.tmp.$$"

    # Build JSON using jq
    {
        echo "{"
        echo "  \"status\": \"$status\","
        echo "  \"test_command\": $(jq -n --arg cmd "$test_cmd" '$cmd'),"
        echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        if [[ -n "$error_msg" ]]; then
            echo "  \"error\": $(jq -n --arg err "$error_msg" '$err'),"
        fi
        if [[ -n "$repairs_attempted" ]]; then
            echo "  \"repairs_attempted\": $(jq -n --arg r "$repairs_attempted" '$r'),"
        fi
        if [[ -n "$diagnostics" ]]; then
            echo "  \"diagnostics\": $(jq -n --arg d "$diagnostics" '$d'),"
        fi
        echo "  \"duration_ms\": 0"
        echo "}"
    } > "$tmp_report"

    # Atomic move
    mv "$tmp_report" "$report_file"
}

# ─── Main orchestrator function ─────────────────────────────────────────
preflight_validate_test_cmd() {
    local test_cmd="${1:-npm test}"

    # Early exit if disabled
    if [[ "${SW_PREFLIGHT_ENABLED:-true}" != "true" ]] && [[ "${SW_PREFLIGHT_ENABLED:-true}" != "1" ]]; then
        return 0
    fi

    local start_time=$(date +%s%N)

    # Phase 1: Detect project type
    local project_info
    project_info=$(_detect_project_info)

    # Phase 2: Probe test command
    local probe_output
    probe_output=$(_probe_test_cmd "$test_cmd" "help")

    # Check if probe succeeded - must not contain common error patterns
    local failure_class
    failure_class=$(classify_test_cmd_failure "$probe_output")

    if [[ "$failure_class" == "unknown" ]]; then
        write_validation_report "PASS" "$test_cmd"
        emit_event "loop.preflight_complete" "status=pass" "command=$test_cmd"
        return 0
    fi

    # Phase 3: Classify failure (already done above)

    # Phase 4: Attempt repair
    local repairs_attempted="$failure_class"
    if attempt_auto_repair "$failure_class" "$project_info"; then
        # Phase 5: Re-probe after repair
        probe_output=$(_probe_test_cmd "$test_cmd" "help")
        failure_class=$(classify_test_cmd_failure "$probe_output")
        if [[ "$failure_class" == "unknown" ]]; then
            write_validation_report "PASS" "$test_cmd" "" "$repairs_attempted"
            emit_event "loop.preflight_complete" "status=pass" "command=$test_cmd" "repairs=$repairs_attempted"
            return 0
        fi
    fi

    # Validation failed after repair attempts
    write_validation_report "FAIL" "$test_cmd" "Test command failed validation and repair" "$repairs_attempted" "$failure_class"
    emit_event "loop.preflight_failed" "command=$test_cmd" "failure_class=$failure_class"

    error "Test command validation failed: $test_cmd"
    error "Failure class: $failure_class"
    error "Repairs attempted: $repairs_attempted"
    return 2
}
