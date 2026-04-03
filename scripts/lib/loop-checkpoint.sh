#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  loop-checkpoint — Sub-iteration checkpoint library for build loop       ║
# ║                                                                         ║
# ║  Saves/restores fine-grained state at step boundaries within each       ║
# ║  loop iteration: post-claude, post-commit, post-test, post-audit,      ║
# ║  post-quality. On restart, skip already-completed steps.               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Module guard - prevent double-sourcing
[[ -n "${_LOOP_CHECKPOINT_LOADED:-}" ]] && return 0
_LOOP_CHECKPOINT_LOADED=1

# ─── Step Constants ─────────────────────────────────────────────────────────
# Numeric ordering for comparison (lower = earlier in iteration)
STEP_POST_CLAUDE=1
STEP_POST_COMMIT=2
STEP_POST_TEST=3
STEP_POST_AUDIT=4
STEP_POST_QUALITY=5

# ─── Helpers ────────────────────────────────────────────────────────────────

sub_checkpoint_step_name() {
    local step_num="${1:-0}"
    case "$step_num" in
        1) echo "post-claude" ;;
        2) echo "post-commit" ;;
        3) echo "post-test" ;;
        4) echo "post-audit" ;;
        5) echo "post-quality" ;;
        *) echo "unknown" ;;
    esac
}

sub_checkpoint_step_num() {
    local step_name="${1:-}"
    case "$step_name" in
        post-claude)  echo "$STEP_POST_CLAUDE" ;;
        post-commit)  echo "$STEP_POST_COMMIT" ;;
        post-test)    echo "$STEP_POST_TEST" ;;
        post-audit)   echo "$STEP_POST_AUDIT" ;;
        post-quality) echo "$STEP_POST_QUALITY" ;;
        *)            echo "0" ;;
    esac
}

sub_checkpoint_completed_steps() {
    local step_name="${1:-}"
    local step_num
    step_num="$(sub_checkpoint_step_num "$step_name")"
    local result=""
    if [[ "$step_num" -ge "$STEP_POST_CLAUDE" ]]; then
        result="- Claude run (code generation)"
    fi
    if [[ "$step_num" -ge "$STEP_POST_COMMIT" ]]; then
        result="${result}
- Auto-commit (git changes saved)"
    fi
    if [[ "$step_num" -ge "$STEP_POST_TEST" ]]; then
        result="${result}
- Test execution (results captured)"
    fi
    if [[ "$step_num" -ge "$STEP_POST_AUDIT" ]]; then
        result="${result}
- Audit agent review"
    fi
    if [[ "$step_num" -ge "$STEP_POST_QUALITY" ]]; then
        result="${result}
- Quality gates evaluation"
    fi
    echo "$result"
}

# ─── Checkpoint Directory ───────────────────────────────────────────────────

_sub_checkpoint_dir() {
    local project_root="${PROJECT_ROOT:-.}"
    echo "${project_root}/.claude/pipeline-artifacts/checkpoints"
}

# ─── Save ───────────────────────────────────────────────────────────────────
# sub_checkpoint_save <iteration> <step_name> <data_json>
# Writes a sub-iteration checkpoint with atomic tmp+mv pattern.

sub_checkpoint_save() {
    local iteration="${1:-0}"
    local step_name="${2:-}"
    local data_json="${3:-{\}}"
    local ckpt_dir
    ckpt_dir="$(_sub_checkpoint_dir)"
    mkdir -p "$ckpt_dir" 2>/dev/null || true

    local step_num
    step_num="$(sub_checkpoint_step_num "$step_name")"

    # Agent number suffix for multi-agent isolation
    local agent_suffix=""
    if [[ "${AGENTS:-1}" -gt 1 ]] && [[ -n "${AGENT_NUM:-}" ]]; then
        agent_suffix="-agent${AGENT_NUM}"
    fi

    local filename="build-${iteration}-${step_name}${agent_suffix}-checkpoint.json"
    local target="${ckpt_dir}/${filename}"
    local tmp_file="${target}.tmp.$$"

    # Build checkpoint JSON — merge caller data with metadata
    local git_sha
    git_sha="$(git rev-parse HEAD 2>/dev/null || echo "unknown")"
    local timestamp
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    jq -n \
        --argjson data "$data_json" \
        --arg step "$step_name" \
        --argjson step_num "$step_num" \
        --argjson iteration "$iteration" \
        --arg git_sha "$git_sha" \
        --arg timestamp "$timestamp" \
        --arg agent "${AGENT_NUM:-1}" \
        '{
            iteration: $iteration,
            step: $step,
            step_num: $step_num,
            git_sha: $git_sha,
            timestamp: $timestamp,
            agent: $agent
        } + $data' > "$tmp_file" 2>/dev/null || {
        rm -f "$tmp_file"
        return 1
    }

    # Atomic write
    if mv "$tmp_file" "$target" 2>/dev/null; then
        return 0
    else
        rm -f "$tmp_file"
        return 1
    fi
}

# ─── Find Latest ────────────────────────────────────────────────────────────
# sub_checkpoint_find_latest
# Returns path to the most recent sub-iteration checkpoint file.
# Selection: highest iteration, then highest step number.

sub_checkpoint_find_latest() {
    local ckpt_dir
    ckpt_dir="$(_sub_checkpoint_dir)"
    [[ -d "$ckpt_dir" ]] || return 1

    # Agent filter for multi-agent mode
    local agent_pattern=""
    if [[ "${AGENTS:-1}" -gt 1 ]] && [[ -n "${AGENT_NUM:-}" ]]; then
        agent_pattern="-agent${AGENT_NUM}"
    fi

    local best_file=""
    local best_iter=0
    local best_step=0

    local f
    for f in "$ckpt_dir"/build-*-checkpoint.json; do
        [[ -f "$f" ]] || continue

        # Filter by agent in multi-agent mode
        if [[ -n "$agent_pattern" ]]; then
            case "$(basename "$f")" in
                *"$agent_pattern"-checkpoint.json) ;;
                *) continue ;;
            esac
        else
            # Single-agent: skip agent-specific checkpoints
            case "$(basename "$f")" in
                *-agent*-checkpoint.json) continue ;;
            esac
        fi

        # Parse iteration and step from JSON (reliable, not filename)
        local f_iter f_step
        f_iter="$(jq -r '.iteration // 0' "$f" 2>/dev/null)" || continue
        f_step="$(jq -r '.step_num // 0' "$f" 2>/dev/null)" || continue

        # Validate
        [[ "$f_iter" =~ ^[0-9]+$ ]] || continue
        [[ "$f_step" =~ ^[0-9]+$ ]] || continue

        if [[ "$f_iter" -gt "$best_iter" ]] || \
           { [[ "$f_iter" -eq "$best_iter" ]] && [[ "$f_step" -gt "$best_step" ]]; }; then
            best_iter="$f_iter"
            best_step="$f_step"
            best_file="$f"
        fi
    done

    if [[ -n "$best_file" ]]; then
        echo "$best_file"
        return 0
    fi
    return 1
}

# ─── Restore ────────────────────────────────────────────────────────────────
# sub_checkpoint_restore <checkpoint_file>
# Reads checkpoint and exports RESTORED_* variables.
# Returns 0 on success, 1 on failure (corrupt file, stale SHA).

sub_checkpoint_restore() {
    local checkpoint_file="${1:-}"
    [[ -f "$checkpoint_file" ]] || return 1

    # Validate JSON
    if ! jq empty "$checkpoint_file" 2>/dev/null; then
        return 1
    fi

    local ckpt_iter ckpt_step ckpt_step_num ckpt_sha ckpt_test_passed
    ckpt_iter="$(jq -r '.iteration // 0' "$checkpoint_file")"
    ckpt_step="$(jq -r '.step // empty' "$checkpoint_file")"
    ckpt_step_num="$(jq -r '.step_num // 0' "$checkpoint_file")"
    ckpt_sha="$(jq -r '.git_sha // empty' "$checkpoint_file")"
    ckpt_test_passed="$(jq -r '.test_passed // empty' "$checkpoint_file")"

    # Validate git SHA is ancestor of current HEAD (guard against stale checkpoint after git reset)
    if [[ -n "$ckpt_sha" && "$ckpt_sha" != "unknown" ]]; then
        if ! git merge-base --is-ancestor "$ckpt_sha" HEAD 2>/dev/null; then
            # Stale checkpoint — SHA is not in current history
            return 1
        fi
    fi

    # Export restored state
    export RESTORED_ITERATION="$ckpt_iter"
    export RESTORED_STEP="$ckpt_step"
    export RESTORED_STEP_NUM="$ckpt_step_num"
    export RESTORED_GIT_SHA="$ckpt_sha"
    export RESTORED_TEST_PASSED="$ckpt_test_passed"

    # Export RESUME_FROM_STEP for the loop's step-skip logic
    export RESUME_FROM_STEP="$ckpt_step"
    export RESUME_FROM_STEP_NUM="$ckpt_step_num"

    return 0
}

# ─── Clean ──────────────────────────────────────────────────────────────────
# sub_checkpoint_clean <keep_iterations>
# Removes sub-iteration checkpoints older than keep_iterations back from the
# highest iteration found. Default: keep last 3.

sub_checkpoint_clean() {
    local keep="${1:-3}"
    local ckpt_dir
    ckpt_dir="$(_sub_checkpoint_dir)"
    [[ -d "$ckpt_dir" ]] || return 0

    # Find the highest iteration number
    local max_iter=0
    local f
    for f in "$ckpt_dir"/build-*-checkpoint.json; do
        [[ -f "$f" ]] || continue
        local f_iter
        f_iter="$(jq -r '.iteration // 0' "$f" 2>/dev/null)" || continue
        [[ "$f_iter" =~ ^[0-9]+$ ]] || continue
        [[ "$f_iter" -gt "$max_iter" ]] && max_iter="$f_iter"
    done

    local cutoff=$(( max_iter - keep ))
    [[ "$cutoff" -lt 1 ]] && return 0

    # Remove checkpoints from iterations below cutoff
    for f in "$ckpt_dir"/build-*-checkpoint.json; do
        [[ -f "$f" ]] || continue
        # Skip non-sub-iteration checkpoints (the main build-checkpoint.json)
        local basename_f
        basename_f="$(basename "$f")"
        case "$basename_f" in
            build-checkpoint.json) continue ;;
        esac

        local f_iter
        f_iter="$(jq -r '.iteration // 0' "$f" 2>/dev/null)" || continue
        [[ "$f_iter" =~ ^[0-9]+$ ]] || continue
        if [[ "$f_iter" -lt "$cutoff" ]]; then
            rm -f "$f"
        fi
    done
}
