#!/usr/bin/env bash
# Module: git-state-validator
# Git state validation hooks for pipeline stages: before/after execution checks
set -euo pipefail

VERSION="0.1.0"

# Module guard
[[ -n "${_MODULE_GIT_STATE_VALIDATOR_LOADED:-}" ]] && return 0; _MODULE_GIT_STATE_VALIDATOR_LOADED=1

# ─── Defaults ──────────────────────────────────────────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_DIR="${STATE_DIR:-$PROJECT_ROOT/.claude}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$STATE_DIR/pipeline-artifacts}"
MANIFEST_FILE="${MANIFEST_FILE:-$ARTIFACTS_DIR/stage-manifests.json}"
STASH_LOG="${STASH_LOG:-$ARTIFACTS_DIR/git-validator-stashes.jsonl}"

# Ensure helpers are loaded
[[ -f "$SCRIPT_DIR/helpers.sh" ]] && source "$SCRIPT_DIR/helpers.sh" 2>/dev/null || true
[[ "$(type -t info 2>/dev/null)" == "function" ]] || info() { echo "$*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]] || warn() { echo "$*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]] || error() { echo "$*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { true; }

# ─── Public API ────────────────────────────────────────────────────────────

# validate_before_stage <stage_id>
# Returns 0 on clean / 1 on abort
validate_before_stage() {
    local stage_id="${1:-}"
    [[ -z "$stage_id" ]] && { error "validate_before_stage: stage_id required"; return 1; }

    # Escape hatches
    [[ "${SW_DISABLE_GIT_VALIDATOR:-0}" == "1" ]] && return 0
    [[ ! -f "$MANIFEST_FILE" ]] && { warn "Git state validator: manifest not found at $MANIFEST_FILE, skipping"; return 0; }

    local before_policy
    before_policy=$(_load_stage_manifest "$stage_id" "before_policy") || return 0
    [[ -z "$before_policy" ]] && before_policy="warn"

    # Downgrade abort to warn in LOCAL_MODE or SW_DOWNGRADE_GIT_VALIDATOR
    if [[ "${LOCAL_MODE:-0}" == "1" ]] || [[ "${SW_DOWNGRADE_GIT_VALIDATOR:-}" == "warn" ]]; then
        [[ "$before_policy" == "abort" ]] && before_policy="warn"
    fi

    local dirty_entries
    dirty_entries=$(_get_dirty_entries "$stage_id" "before") || return 0

    if [[ -z "$dirty_entries" ]]; then
        emit_event "git_state.before_ok" "stage=$stage_id" "policy=$before_policy"
        return 0
    fi

    case "$before_policy" in
        auto_stash)
            if _auto_stash_dirty "$stage_id"; then
                emit_event "git_state.before_stashed" "stage=$stage_id" "entry_count=$(echo "$dirty_entries" | wc -l)"
                return 0
            else
                error "Failed to stash changes before $stage_id"
                emit_event "git_state.before_stash_failed" "stage=$stage_id"
                return 1
            fi
            ;;
        abort)
            emit_event "git_state.before_fail" "stage=$stage_id" "policy=$before_policy" "entry_count=$(echo "$dirty_entries" | wc -l)"
            _format_recovery_hint "before" "$stage_id" "$dirty_entries"
            return 1
            ;;
        warn)
            emit_event "git_state.before_warn" "stage=$stage_id" "entry_count=$(echo "$dirty_entries" | wc -l)"
            warn "Git state validation: dirty working tree before $stage_id (policy=warn)"
            warn "  Files: $(echo "$dirty_entries" | head -3 | tr '\n' ' ')"
            return 0
            ;;
        *)
            warn "Git state validation: unknown before_policy '$before_policy' for stage $stage_id"
            return 0
            ;;
    esac
}

# validate_after_stage <stage_id> <pre_sha>
# Returns 0 on clean / 1 on abort
validate_after_stage() {
    local stage_id="${1:-}"
    local pre_sha="${2:-}"
    [[ -z "$stage_id" ]] && { error "validate_after_stage: stage_id required"; return 1; }

    # Escape hatches
    [[ "${SW_DISABLE_GIT_VALIDATOR:-0}" == "1" ]] && return 0
    [[ ! -f "$MANIFEST_FILE" ]] && return 0
    [[ -z "$pre_sha" ]] && return 0

    local after_policy
    after_policy=$(_load_stage_manifest "$stage_id" "after_policy") || return 0
    [[ -z "$after_policy" ]] && after_policy="warn"

    # Downgrade abort to warn in LOCAL_MODE or SW_DOWNGRADE_GIT_VALIDATOR
    if [[ "${LOCAL_MODE:-0}" == "1" ]] || [[ "${SW_DOWNGRADE_GIT_VALIDATOR:-}" == "warn" ]]; then
        [[ "$after_policy" == "abort" ]] && after_policy="warn"
    fi

    local unexpected_entries
    unexpected_entries=$(_get_unexpected_entries "$stage_id" "$pre_sha") || return 0

    if [[ -z "$unexpected_entries" ]]; then
        emit_event "git_state.after_ok" "stage=$stage_id" "policy=$after_policy"
        return 0
    fi

    case "$after_policy" in
        abort)
            emit_event "git_state.after_fail" "stage=$stage_id" "policy=$after_policy" "entry_count=$(echo "$unexpected_entries" | wc -l)"
            _format_recovery_hint "after" "$stage_id" "$unexpected_entries"
            return 1
            ;;
        warn)
            emit_event "git_state.after_warn" "stage=$stage_id" "entry_count=$(echo "$unexpected_entries" | wc -l)"
            warn "Git state validation: unexpected file changes after $stage_id (policy=warn)"
            warn "  Files: $(echo "$unexpected_entries" | head -3 | tr '\n' ' ')"
            return 0
            ;;
        *)
            warn "Git state validation: unknown after_policy '$after_policy' for stage $stage_id"
            return 0
            ;;
    esac
}

# ─── Private Helpers ───────────────────────────────────────────────────────

# _load_stage_manifest <stage_id> <field>
# Reads a field from the stage manifest for the given stage
_load_stage_manifest() {
    local stage_id="$1"
    local field="$2"

    jq -r --arg id "$stage_id" --arg fld "$field" \
        '.stages[$id][$fld] // empty' \
        "$MANIFEST_FILE" 2>/dev/null || true
}

# _get_dirty_entries <stage_id> <phase>
# Returns list of dirty entries (uncommitted + untracked)
# Only returns entries that match forbidden_paths patterns
_get_dirty_entries() {
    local stage_id="$1"
    local phase="$2"

    local forbidden_paths
    forbidden_paths=$(_load_stage_manifest "$stage_id" "forbidden_paths") || true
    [[ -z "$forbidden_paths" ]] && return 0

    local dirty_list
    dirty_list=$(git status --porcelain 2>/dev/null | awk '{print $NF}' || true)
    [[ -z "$dirty_list" ]] && return 0

    local matching=""
    while IFS= read -r path; do
        if _matches_any_pattern "$path" "$forbidden_paths"; then
            matching="${matching}${path}"$'\n'
        fi
    done < <(echo "$dirty_list")

    echo "$matching"
}

# _get_unexpected_entries <stage_id> <pre_sha>
# Returns list of files changed after the stage that don't match expected_paths
_get_unexpected_entries() {
    local stage_id="$1"
    local pre_sha="$2"

    local expected_paths
    expected_paths=$(_load_stage_manifest "$stage_id" "expected_paths") || true

    # Get files changed in the stage
    local changed_files
    changed_files=$(git diff --name-only "$pre_sha..HEAD" 2>/dev/null || true)
    [[ -z "$changed_files" ]] && return 0

    # Also include uncommitted changes
    changed_files="${changed_files}"$'\n'"$(git status --porcelain 2>/dev/null | awk '{print $NF}' || true)"
    changed_files=$(echo "$changed_files" | sort -u | grep -v '^$' || true)
    [[ -z "$changed_files" ]] && return 0

    # Check each changed file against expected patterns
    local unexpected=""
    while IFS= read -r path; do
        if ! _matches_any_pattern "$path" "$expected_paths"; then
            unexpected="${unexpected}${path}"$'\n'
        fi
    done < <(echo "$changed_files")

    echo "$unexpected"
}

# _matches_any_pattern <path> <patterns_json_array>
# Returns 0 if path matches any glob pattern in the array
_matches_any_pattern() {
    local path="$1"
    local patterns_json="$2"

    # Handle empty patterns
    if [[ -z "$patterns_json" ]] || [[ "$patterns_json" == "[]" ]] || [[ "$patterns_json" == "null" ]]; then
        return 1
    fi

    # Extract patterns from JSON array and test each one
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        # Bash 3.2 compatible glob matching via case statement
        case "$path" in
            $pattern) return 0 ;;
        esac
    done < <(jq -r '.[]?' <<< "$patterns_json" 2>/dev/null || true)

    return 1
}

# _auto_stash_dirty <stage_id>
# Stashes uncommitted and untracked changes
_auto_stash_dirty() {
    local stage_id="$1"

    # Only auto-stash in daemon or CI mode
    if [[ "${SHIPWRIGHT_DAEMON:-0}" != "1" && "${CI:-}" != "true" ]]; then
        warn "Git state validation: dirty working tree detected in interactive mode"
        return 1
    fi

    local stash_msg
    stash_msg="shipwright:pre-${stage_id}:$(date +%s):$$"

    if ! git stash push -u -m "$stash_msg" >/dev/null 2>&1; then
        error "Failed to stash dirty changes"
        return 1
    fi

    # Record stash in atomic write
    local stash_ref
    stash_ref=$(git rev-parse stash 2>/dev/null || echo "")
    if [[ -n "$stash_ref" ]]; then
        local tmp_log
        tmp_log=$(mktemp) || return 1
        {
            jq -n --arg ref "$stash_ref" --arg msg "$stash_msg" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '{stash_ref: $ref, message: $msg, timestamp: $ts, worktree: env.PWD, pid: env.PPID}'
        } >> "$tmp_log" 2>/dev/null || true

        if [[ -f "$tmp_log" ]] && [[ -s "$tmp_log" ]]; then
            # Use atomic write: tmp + mv
            if mkdir -p "$ARTIFACTS_DIR" 2>/dev/null; then
                mv "$tmp_log" "$STASH_LOG" 2>/dev/null || cat "$tmp_log" >> "$STASH_LOG"
            fi
        fi
        rm -f "$tmp_log"
    fi

    return 0
}

# _format_recovery_hint <phase> <stage_id> <entries>
# Prints an actionable recovery hint to stderr
_format_recovery_hint() {
    local phase="$1"
    local stage_id="$2"
    local entries="$3"

    local uncommitted untracked
    uncommitted=$(echo "$entries" | grep '^M ' | wc -l)
    untracked=$(echo "$entries" | grep '??' | wc -l)

    cat >&2 <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✗ Git state validation failed (${phase}) before stage: ${stage_id}

Summary:
  Uncommitted files: ${uncommitted}
  Untracked files:   ${untracked}

Top offenders (first 5):
$(echo "$entries" | head -5 | sed 's/^/  /')

Recovery Options:
  1. Stash and resume:
     git stash push -u -m "pre-${stage_id}" && shipwright pipeline resume

  2. Discard all changes (CAREFUL):
     git checkout -- . && git clean -fd && shipwright pipeline resume

  3. Examine changes:
     git status

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

return 0
