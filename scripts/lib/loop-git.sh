#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Loop Git Helpers — commit tracking, validation, auto-commit              ║
# ║                                                                         ║
# ║  This module handles all git operations: counting commits, checking diffs, ║
# ║  validating Claude output before committing, and auto-committing.         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# Module guard — prevent double-sourcing
[[ -z "${_LOOP_GIT_SH_LOADED:-}" ]] || return 0
readonly _LOOP_GIT_SH_LOADED=1

# ─── Semantic Validation for Claude Output ────────────────────────────────
# Validates changed files before commit to catch syntax errors and API error leakage.
validate_claude_output() {
    local workdir="${1:-.}"
    local issues=0

    # Check for syntax errors in changed files
    local changed_files
    changed_files=$(git -C "$workdir" diff --cached --name-only 2>/dev/null || git -C "$workdir" diff --name-only 2>/dev/null)

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ ! -f "$workdir/$file" ]] && continue

        case "$file" in
            *.sh)
                if ! bash -n "$workdir/$file" 2>/dev/null; then
                    warn "Syntax error in shell script: $file"
                    issues=$((issues + 1))
                fi
                ;;
            *.py)
                if command -v python3 >/dev/null 2>&1; then
                    if ! python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$workdir/$file" 2>/dev/null; then
                        warn "Syntax error in Python file: $file"
                        issues=$((issues + 1))
                    fi
                fi
                ;;
            *.json)
                if command -v jq >/dev/null 2>&1 && ! jq empty "$workdir/$file" 2>/dev/null; then
                    warn "Invalid JSON: $file"
                    issues=$((issues + 1))
                fi
                ;;
            *.ts|*.js|*.tsx|*.jsx)
                # Check for obvious corruption: API error text leaked into source
                if grep -qE '(CLAUDE_CODE_OAUTH_TOKEN|api key|rate limit|503 Service|DOCTYPE html)' "$workdir/$file" 2>/dev/null; then
                    warn "Claude API error leaked into source file: $file"
                    issues=$((issues + 1))
                fi
                ;;
        esac
    done <<< "$changed_files"

    # Check for obviously corrupt output (API errors dumped as code)
    local total_changed
    total_changed=$(echo "$changed_files" | grep -c '.' 2>/dev/null || true)
    total_changed="${total_changed:-0}"
    if [[ "$total_changed" -eq 0 ]]; then
        warn "Claude iteration produced no file changes"
        issues=$((issues + 1))
    fi

    return "$issues"
}

# ─── Git Commit Count ──────────────────────────────────────────────────────
git_commit_count() {
    git -C "$PROJECT_ROOT" rev-list --count HEAD 2>/dev/null || echo 0
}

# ─── Git Recent Log ────────────────────────────────────────────────────────
git_recent_log() {
    git -C "$PROJECT_ROOT" log --oneline -20 2>/dev/null || echo "(no commits)"
}

# ─── Git Diff Stat ────────────────────────────────────────────────────────
git_diff_stat() {
    git -C "$PROJECT_ROOT" diff --stat HEAD~1 2>/dev/null | tail -1 || echo ""
}

# ─── Auto Commit ──────────────────────────────────────────────────────────
git_auto_commit() {
    local work_dir="${1:-$PROJECT_ROOT}"
    # Only commit if there are changes
    if git -C "$work_dir" diff --quiet && git -C "$work_dir" diff --cached --quiet; then
        # Check for untracked files
        local untracked
        untracked="$(git -C "$work_dir" ls-files --others --exclude-standard | head -1)"
        if [[ -z "$untracked" ]]; then
            return 1  # Nothing to commit
        fi
    fi

    git -C "$work_dir" add -A 2>/dev/null || true

    # Semantic validation before commit — skip commit if validation fails
    if ! validate_claude_output "$work_dir"; then
        warn "Validation failed — skipping commit for this iteration"
        git -C "$work_dir" reset --hard HEAD 2>/dev/null || true
        return 1
    fi

    git -C "$work_dir" commit -m "loop: iteration $ITERATION — autonomous progress" --no-verify 2>/dev/null || return 1
    return 0
}
