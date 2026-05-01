#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  merge-conflict.sh — Merge conflict prediction & auto-resolution         ║
# ║                                                                           ║
# ║  Public API:                                                             ║
# ║    mc_predict <base> <head> [--out FILE]      0=clean 1=conflict 2=err   ║
# ║    mc_auto_resolve <base> <head> [--strategies S] [--max-files N]        ║
# ║                              [--out FILE]     0=resolved 1=fail 2=err    ║
# ║    mc_report <pred.json> <res.json> [--out FILE]                         ║
# ║    mc_guided_fallback <pred.json> [--out FILE]                           ║
# ║                                                                           ║
# ║  All worktree mutation happens in throwaway temp dirs (mktemp -d) that   ║
# ║  are removed via EXIT trap. The user's working tree is never touched.    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_MERGE_CONFLICT_LOADED:-}" ]] && return 0
_MERGE_CONFLICT_LOADED=1

VERSION="1.0.0"

ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
MC_MAX_FILES_DEFAULT="${MC_MAX_FILES:-5}"
MC_AGGRESSIVE="${MC_AGGRESSIVE:-false}"
MC_STRATEGIES_DEFAULT="recursive,patience"

# ─── Internal: track temp worktrees for cleanup ──────────────────────────────
_MC_TEMP_WORKTREES=""

_mc_cleanup_worktrees() {
    local wt
    for wt in $_MC_TEMP_WORKTREES; do
        [[ -d "$wt" ]] || continue
        git worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt" 2>/dev/null || true
    done
    _MC_TEMP_WORKTREES=""
}

# Install trap once. Preserve any prior EXIT trap.
_mc_install_trap() {
    [[ -n "${_MC_TRAP_INSTALLED:-}" ]] && return 0
    _MC_TRAP_INSTALLED=1
    local prior
    prior=$(trap -p EXIT 2>/dev/null | sed -E "s/^trap -- '(.*)' EXIT$/\1/" || true)
    if [[ -n "$prior" ]]; then
        trap "$prior; _mc_cleanup_worktrees" EXIT
    else
        trap '_mc_cleanup_worktrees' EXIT
    fi
}

# Sets global _MC_LAST_WORKTREE on success. Avoids command-substitution
# subshells (which would fire the EXIT trap and remove the worktree).
_mc_temp_worktree() {
    local label="${1:-mc}"
    local ref="${2:-HEAD}"
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/sw-mc-${label}-$$-XXXXXX")
    if ! git worktree add --detach --quiet "$dir" "$ref" >/dev/null 2>&1; then
        rm -rf "$dir" 2>/dev/null || true
        _MC_LAST_WORKTREE=""
        return 1
    fi
    _MC_TEMP_WORKTREES="$_MC_TEMP_WORKTREES $dir"
    _mc_install_trap
    _MC_LAST_WORKTREE="$dir"
    return 0
}

_mc_atomic_write() {
    local target="$1"; shift
    local tmp="${target}.tmp.$$"
    mkdir -p "$(dirname "$target")" 2>/dev/null || true
    cat > "$tmp"
    mv -f "$tmp" "$target"
}

_mc_git_supports_merge_tree_write() {
    [[ "${MC_FORCE_LEGACY:-0}" == "1" ]] && return 1
    git merge-tree --help 2>&1 | grep -q -- '--write-tree' 2>/dev/null
}

_mc_emit() {
    local type="$1"; shift
    if command -v emit_event >/dev/null 2>&1; then
        emit_event "$type" "$@" 2>/dev/null || true
    fi
}

# ─── Public: mc_predict ──────────────────────────────────────────────────────
# Args: <base_ref> <head_ref> [--out FILE]
# Exit: 0=clean, 1=conflict, 2=error
mc_predict() {
    local base="" head="" out=""
    base="${1:-}"; head="${2:-}"; shift $(( $# < 2 ? $# : 2 )) || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out) out="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [[ -z "$base" || -z "$head" ]] && { echo "mc_predict: base and head required" >&2; return 2; }

    local base_sha head_sha
    base_sha=$(git rev-parse --verify "$base^{commit}" 2>/dev/null) || { echo "mc_predict: invalid base ref: $base" >&2; return 2; }
    head_sha=$(git rev-parse --verify "$head^{commit}" 2>/dev/null) || { echo "mc_predict: invalid head ref: $head" >&2; return 2; }

    local git_version
    git_version=$(git --version | awk '{print $3}' 2>/dev/null || echo "unknown")

    local conflicts_json="[]"
    local clean="true"
    local method="merge-tree"

    if _mc_git_supports_merge_tree_write; then
        # Modern path: git merge-tree --write-tree
        local mt_out mt_rc
        mt_out=$(git merge-tree --write-tree --name-only --messages "$base_sha" "$head_sha" 2>&1) && mt_rc=0 || mt_rc=$?
        if [[ "$mt_rc" -eq 0 ]]; then
            clean="true"
        else
            # On conflict, output is: <tree-oid>\n<conflict-files>\n\n<messages>
            clean="false"
            local files
            files=$(printf '%s\n' "$mt_out" | awk 'NR>1 {if ($0=="") exit; print}' | grep -v '^$' || true)
            if [[ -n "$files" ]]; then
                conflicts_json=$(printf '%s\n' "$files" | jq -R -s 'split("\n") | map(select(length>0)) | map({path: ., hunks: []})')
            fi
        fi
    else
        # Legacy path: dry-run merge in throwaway worktree
        method="legacy-worktree"
        local wt
        _mc_temp_worktree "predict" "$base_sha" || { echo "mc_predict: worktree create failed" >&2; return 2; }
        wt="$_MC_LAST_WORKTREE"
        local merge_rc=0
        git -C "$wt" merge --no-commit --no-ff "$head_sha" >/dev/null 2>&1 || merge_rc=$?
        if [[ "$merge_rc" -eq 0 ]]; then
            clean="true"
            git -C "$wt" merge --abort >/dev/null 2>&1 || true
        else
            clean="false"
            local files
            files=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null || true)
            if [[ -n "$files" ]]; then
                conflicts_json=$(printf '%s\n' "$files" | jq -R -s 'split("\n") | map(select(length>0)) | map({path: ., hunks: []})')
            fi
            git -C "$wt" merge --abort >/dev/null 2>&1 || true
        fi
    fi

    local n_conflicts
    n_conflicts=$(echo "$conflicts_json" | jq 'length' 2>/dev/null || echo 0)

    local payload
    payload=$(jq -n \
        --arg base "$base" --arg head "$head" \
        --arg base_sha "$base_sha" --arg head_sha "$head_sha" \
        --arg git_version "$git_version" --arg method "$method" \
        --argjson clean "$clean" --argjson conflicts "$conflicts_json" \
        '{clean:$clean, base:$base, head:$head, base_sha:$base_sha, head_sha:$head_sha,
          git_version:$git_version, method:$method, conflict_count:($conflicts|length),
          conflicts:$conflicts}')

    if [[ -n "$out" ]]; then
        printf '%s\n' "$payload" | _mc_atomic_write "$out"
    else
        printf '%s\n' "$payload"
    fi

    _mc_emit "merge.conflict.predicted" "conflicts=$n_conflicts" "method=$method"

    [[ "$clean" == "true" ]] && return 0 || return 1
}

# ─── Internal: should we attempt aggressive strategies for this set? ─────────
# Returns 0 (yes, safe) if conflicts ≤ max_files AND no binary AND no lockfile.
_mc_safe_for_aggressive() {
    local base_sha="$1" head_sha="$2" max_files="$3"
    local files
    files=$(git diff --name-only "$base_sha" "$head_sha" 2>/dev/null || echo "")
    local count=0 f
    for f in $files; do
        count=$((count + 1))
        case "$f" in
            *.lock|*.lockb|*.lockfile|package-lock.json|yarn.lock|pnpm-lock.yaml|Cargo.lock|Gemfile.lock|poetry.lock|composer.lock)
                return 1 ;;
        esac
    done
    [[ "$count" -gt "$max_files" ]] && return 1
    # Binary detection via numstat: '-\t-\tpath' indicates binary
    if git diff --numstat "$base_sha" "$head_sha" 2>/dev/null | awk '$1=="-" && $2=="-" {found=1; exit} END{exit !found}'; then
        return 1
    fi
    return 0
}

# ─── Public: mc_auto_resolve ─────────────────────────────────────────────────
# Args: <base_ref> <head_ref> [--strategies "s1,s2"] [--max-files N] [--out FILE]
# Exit: 0=resolved, 1=all strategies failed, 2=error
mc_auto_resolve() {
    local base="" head="" strategies="$MC_STRATEGIES_DEFAULT" out=""
    local max_files="$MC_MAX_FILES_DEFAULT"
    base="${1:-}"; head="${2:-}"; shift $(( $# < 2 ? $# : 2 )) || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --strategies) strategies="$2"; shift 2 ;;
            --max-files)  max_files="$2"; shift 2 ;;
            --out)        out="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [[ -z "$base" || -z "$head" ]] && { echo "mc_auto_resolve: base and head required" >&2; return 2; }

    local base_sha head_sha
    base_sha=$(git rev-parse --verify "$base^{commit}" 2>/dev/null) || return 2
    head_sha=$(git rev-parse --verify "$head^{commit}" 2>/dev/null) || return 2

    local safe="false"
    if _mc_safe_for_aggressive "$base_sha" "$head_sha" "$max_files"; then
        safe="true"
    fi

    local attempts_json="[]"
    local resolved="false"
    local resolved_strategy="" resolved_tree=""

    local IFS_SAVE="$IFS"
    IFS=','
    # shellcheck disable=SC2206
    local strat_array=( $strategies )
    IFS="$IFS_SAVE"

    local strat
    for strat in "${strat_array[@]}"; do
        strat="${strat## }"; strat="${strat%% }"
        [[ -z "$strat" ]] && continue

        # Aggressive strategies require safety guard
        case "$strat" in
            ours|theirs|union)
                if [[ "$safe" != "true" && "$MC_AGGRESSIVE" != "true" ]]; then
                    attempts_json=$(echo "$attempts_json" | jq --arg s "$strat" \
                        '. + [{strategy:$s, status:"skipped", reason:"unsafe_for_aggressive"}]')
                    continue
                fi
                ;;
        esac

        local wt
        if ! _mc_temp_worktree "resolve-$strat" "$base_sha"; then
            attempts_json=$(echo "$attempts_json" | jq --arg s "$strat" \
                '. + [{strategy:$s, status:"error", reason:"worktree_create_failed"}]')
            continue
        fi
        wt="$_MC_LAST_WORKTREE"

        local merge_args=""
        case "$strat" in
            recursive) merge_args="" ;;
            patience)  merge_args="-X patience" ;;
            ours)      merge_args="-X ours" ;;
            theirs)    merge_args="-X theirs" ;;
            union)     merge_args="" ;;  # union: handled via .gitattributes merge driver below
            *) merge_args="-X $strat" ;;
        esac

        # For union strategy, install a per-worktree merge driver via .gitattributes
        # so git's built-in `union` driver concatenates both sides instead of leaving markers.
        if [[ "$strat" == "union" ]]; then
            printf '* merge=union\n' > "$wt/.gitattributes"
            git -C "$wt" add .gitattributes >/dev/null 2>&1 || true
            git -C "$wt" -c user.email=mc@local -c user.name=mc \
                commit --no-verify --quiet -m "mc: temp union attributes" >/dev/null 2>&1 || true
        fi

        local rc=0
        # shellcheck disable=SC2086
        git -C "$wt" merge --no-edit $merge_args "$head_sha" >/dev/null 2>&1 || rc=$?

        if [[ "$rc" -eq 0 ]]; then
            local marker_files
            marker_files=$(git -C "$wt" grep -l --untracked '^<<<<<<< ' 2>/dev/null | wc -l | awk '{print $1}')
            if [[ "${marker_files:-0}" -eq 0 ]]; then
                resolved="true"
                resolved_strategy="$strat"
                resolved_tree=$(git -C "$wt" rev-parse HEAD)
                attempts_json=$(echo "$attempts_json" | jq --arg s "$strat" --arg t "$resolved_tree" \
                    '. + [{strategy:$s, status:"success", tree:$t}]')
                break
            fi
            git -C "$wt" merge --abort >/dev/null 2>&1 || true
            attempts_json=$(echo "$attempts_json" | jq --arg s "$strat" \
                '. + [{strategy:$s, status:"failed", reason:"residual_markers"}]')
        else
            git -C "$wt" merge --abort >/dev/null 2>&1 || true
            attempts_json=$(echo "$attempts_json" | jq --arg s "$strat" \
                '. + [{strategy:$s, status:"failed", reason:"merge_conflict"}]')
        fi
    done

    local payload
    payload=$(jq -n --argjson resolved "$resolved" \
        --arg strategy "$resolved_strategy" --arg tree "$resolved_tree" \
        --argjson attempts "$attempts_json" --argjson safe "$safe" \
        '{resolved:$resolved, strategy:$strategy, tree:$tree,
          aggressive_safe:$safe, attempts:$attempts}')

    if [[ -n "$out" ]]; then
        printf '%s\n' "$payload" | _mc_atomic_write "$out"
    else
        printf '%s\n' "$payload"
    fi

    if [[ "$resolved" == "true" ]]; then
        _mc_emit "merge.conflict.resolved" "strategy=$resolved_strategy"
        return 0
    else
        _mc_emit "merge.conflict.auto_resolve_failed" "strategies=$strategies"
        return 1
    fi
}

# ─── Public: mc_report ───────────────────────────────────────────────────────
# Args: <prediction_json_path> <resolution_json_path> [--out FILE]
mc_report() {
    local pred="${1:-}" res="${2:-}" out=""
    shift $(( $# < 2 ? $# : 2 )) || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out) out="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [[ -f "$pred" ]] || { echo "mc_report: prediction file not found: $pred" >&2; return 2; }

    local res_blob='{}'
    [[ -f "$res" ]] && res_blob=$(cat "$res")

    local payload
    payload=$(jq -n \
        --slurpfile p "$pred" --argjson r "$res_blob" \
        '{prediction:$p[0], resolution:$r,
          summary:{
              clean:$p[0].clean,
              conflict_count:$p[0].conflict_count,
              resolved:($r.resolved // false),
              strategy:($r.strategy // ""),
              attempts:(($r.attempts // []) | length)
          }}')

    if [[ -n "$out" ]]; then
        printf '%s\n' "$payload" | _mc_atomic_write "$out"
    else
        printf '%s\n' "$payload"
    fi
}

# ─── Public: mc_guided_fallback ──────────────────────────────────────────────
# Args: <prediction_json_path> [--out FILE]
mc_guided_fallback() {
    local pred="${1:-}" out=""
    shift $(( $# >= 1 ? 1 : 0 )) || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out) out="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [[ -f "$pred" ]] || { echo "mc_guided_fallback: prediction file not found: $pred" >&2; return 2; }

    local base head count
    base=$(jq -r '.base // "base"' "$pred")
    head=$(jq -r '.head // "HEAD"' "$pred")
    count=$(jq -r '.conflict_count // 0' "$pred")

    local md
    md=$(printf '# Guided Merge Conflict Resolution\n\n'
         printf '**Base:** `%s`  \n**Head:** `%s`  \n**Conflicts:** %s files\n\n' "$base" "$head" "$count"
         printf '## Conflicting files\n\n'
         jq -r '.conflicts[]?.path | "- `\(.)`"' "$pred" 2>/dev/null
         printf '\n## Recommended commands\n\n'
         printf '```bash\n'
         printf 'git checkout %s\n' "$head"
         printf 'git merge %s\n' "$base"
         printf '# Resolve markers in each file, then:\n'
         printf 'git add -A && git commit\n'
         printf '```\n'
         printf '\n## Notes\n\n'
         printf -- '- Auto-resolution was not safe for this conflict set.\n'
         printf -- '- Inspect each file manually; pay special attention to lockfiles and binary content.\n')

    if [[ -n "$out" ]]; then
        printf '%s\n' "$md" | _mc_atomic_write "$out"
    else
        printf '%s\n' "$md"
    fi

    _mc_emit "merge.conflict.guided_written" "conflicts=$count"
}
