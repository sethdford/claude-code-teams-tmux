#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/project-signals — Repo-shape signal detectors             ║
# ║  Pure observation. Never decides a template, never mutates the repo.      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   source "$SCRIPT_DIR/lib/project-signals.sh"
#   project_collect_signals "/path/to/repo" "vitest" 120 40
#
# Provides:
#   - detect_monorepo(root)                                   — workspaces
#   - detect_ci_maturity(root)                                — CI configs
#   - detect_test_maturity(root, framework, srcN, testN)      — test posture
#   - detect_repo_size(root, srcN)                            — commits/files
#   - detect_activity_level(root)                             — recency
#   - project_collect_signals(root, framework, srcN, testN)   — all of them
#
# Contract shared by every detector in this file:
#   * total — always exits 0, on every path, for every input
#   * emits exactly one JSON object on stdout that parses under `jq -e .`
#   * when a signal cannot be observed it emits a sentinel value plus
#     "reason": "detection_skipped" — it never guesses
#   * reads the filesystem only; never writes, never calls the network
#
# The counts are injected by the caller (prep has already computed them) so a
# detector never re-walks a tree someone else already walked. Passing an empty
# string makes the detector count for itself, which is what standalone callers
# and the tests want.

[[ -n "${_PROJECT_SIGNALS_LOADED:-}" ]] && return 0
_PROJECT_SIGNALS_LOADED=1

# ─── Internal helpers ───────────────────────────────────────────────────────

# Run a command with a wall-clock bound when `timeout` is available.
# Detectors must never hang a pipeline on a wedged git process.
_sig_bounded() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 "$@" 2>/dev/null || true
    else
        "$@" 2>/dev/null || true
    fi
}

# Echo the argument when it is a non-negative integer, else echo nothing.
_sig_int() {
    case "${1:-}" in
        ''|*[!0-9]*) return 0 ;;
        *) echo "$1" ;;
    esac
}

_sig_count_src_files() {
    local root="$1"
    find "$root" \
        \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
           -o -name "*.py" -o -name "*.rb" -o -name "*.go" -o -name "*.rs" \
           -o -name "*.java" -o -name "*.sh" \) \
        -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/vendor/*" \
        -not -path "*/target/*" 2>/dev/null | wc -l | tr -d ' '
}

_sig_count_test_files() {
    local root="$1"
    find "$root" \
        \( -name "*.test.*" -o -name "*.spec.*" -o -name "*_test.*" -o -name "test_*" \) \
        -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | wc -l | tr -d ' '
}

# Count directories matching a workspace glob that actually contain a package
# manifest. Runs in a subshell so `nullglob` never leaks into the caller.
_sig_count_glob_packages() {
    local root="$1" pattern="$2"
    (
        shopt -s nullglob 2>/dev/null || true
        local count=0 dir
        for dir in "$root"/$pattern; do
            [[ -d "$dir" ]] || continue
            if [[ -f "$dir/package.json" || -f "$dir/Cargo.toml" || \
                  -f "$dir/go.mod" || -f "$dir/pyproject.toml" ]]; then
                count=$((count + 1))
            fi
        done
        echo "$count"
    )
}

# ─── detect_monorepo ────────────────────────────────────────────────────────
# {is_monorepo, workspace_count, type, reason}
detect_monorepo() {
    local root="${1:-.}"
    local wtype="none" patterns="" reason="no workspace configuration found"
    local count=0

    if [[ ! -d "$root" ]]; then
        jq -n '{is_monorepo:false, workspace_count:0, type:"none", reason:"detection_skipped"}'
        return 0
    fi

    if [[ -f "$root/pnpm-workspace.yaml" ]]; then
        wtype="pnpm"
        patterns=$(sed -n 's/^[[:space:]]*-[[:space:]]*//p' "$root/pnpm-workspace.yaml" 2>/dev/null \
                   | tr -d "\"'" || true)
    elif [[ -f "$root/rush.json" ]]; then
        wtype="rush"
        patterns=$(jq -r '(.projects // [])[] | .projectFolder // empty' "$root/rush.json" 2>/dev/null || true)
    elif [[ -f "$root/lerna.json" ]] && jq -e '.packages' "$root/lerna.json" >/dev/null 2>&1; then
        wtype="lerna"
        patterns=$(jq -r '(.packages // [])[]' "$root/lerna.json" 2>/dev/null || true)
    elif [[ -f "$root/package.json" ]] && jq -e '.workspaces' "$root/package.json" >/dev/null 2>&1; then
        wtype="npm"
        [[ -f "$root/yarn.lock" ]] && wtype="yarn"
        patterns=$(jq -r '
            .workspaces
            | if type == "array" then .[]
              elif type == "object" then (.packages // [])[]
              else empty end' "$root/package.json" 2>/dev/null || true)
    elif [[ -f "$root/go.work" ]]; then
        wtype="go"
        patterns=$(sed -n -e 's/^[[:space:]]*use[[:space:]]\{1,\}\([^ (][^ ]*\).*$/\1/p' \
                          -e '/^[[:space:]]*use[[:space:]]*(/,/^[[:space:]]*)/ s/^[[:space:]]*\([.\/][^ )]*\)[[:space:]]*$/\1/p' \
                   "$root/go.work" 2>/dev/null || true)
    elif [[ -f "$root/Cargo.toml" ]] && grep -q '^\[workspace\]' "$root/Cargo.toml" 2>/dev/null; then
        wtype="cargo"
        patterns=$(sed -n '/^\[workspace\]/,/^\[[^w]/p' "$root/Cargo.toml" 2>/dev/null \
                   | sed -n '/members[[:space:]]*=/,/\]/p' \
                   | tr ',' '\n' | sed -n 's/.*"\([^"]*\)".*/\1/p' || true)
    fi

    if [[ "$wtype" == "none" ]]; then
        jq -n --arg reason "$reason" \
            '{is_monorepo:false, workspace_count:0, type:"none", reason:$reason}'
        return 0
    fi

    local pattern_count=0 pattern resolved
    while IFS= read -r pattern; do
        [[ -n "$pattern" ]] || continue
        pattern="${pattern#./}"
        pattern_count=$((pattern_count + 1))
        resolved=$(_sig_count_glob_packages "$root" "$pattern")
        count=$((count + ${resolved:-0}))
    done <<< "$patterns"

    # A declared workspace whose packages are not on disk yet (fresh scaffold,
    # sparse checkout) still counts as one workspace per pattern — the intent
    # is declared even when the directories are not there to be walked.
    [[ "$count" -eq 0 && "$pattern_count" -gt 0 ]] && count="$pattern_count"

    if [[ "$count" -eq 0 ]]; then
        jq -n --arg t "$wtype" \
            '{is_monorepo:false, workspace_count:0, type:$t,
              reason:"workspace config present but no packages resolved"}'
        return 0
    fi

    jq -n --arg t "$wtype" --argjson c "$count" \
        '{is_monorepo:true, workspace_count:$c, type:$t,
          reason:("\($c) \($t) workspace package(s)")}'
}

# ─── detect_ci_maturity ─────────────────────────────────────────────────────
# {has_ci, ci_types, workflow_count, maturity, reason}
detect_ci_maturity() {
    local root="${1:-.}"
    if [[ ! -d "$root" ]]; then
        jq -n '{has_ci:false, ci_types:[], workflow_count:0, maturity:"none", reason:"detection_skipped"}'
        return 0
    fi

    local types="" count=0 n

    if [[ -d "$root/.github/workflows" ]]; then
        n=$(find "$root/.github/workflows" -maxdepth 1 \( -name "*.yml" -o -name "*.yaml" \) \
            -type f 2>/dev/null | wc -l | tr -d ' ')
        if [[ "${n:-0}" -gt 0 ]]; then
            types="${types}github_actions"$'\n'
            count=$((count + n))
        fi
    fi
    if [[ -f "$root/.circleci/config.yml" || -f "$root/.circleci/config.yaml" ]]; then
        types="${types}circleci"$'\n'; count=$((count + 1))
    fi
    if [[ -f "$root/.gitlab-ci.yml" ]]; then
        types="${types}gitlab"$'\n'; count=$((count + 1))
    fi
    if [[ -f "$root/Jenkinsfile" ]]; then
        types="${types}jenkins"$'\n'; count=$((count + 1))
    fi
    if [[ -f "$root/.travis.yml" ]]; then
        types="${types}travis"$'\n'; count=$((count + 1))
    fi

    local maturity="none" reason="no CI configuration found"
    if [[ "$count" -ge 6 ]]; then
        maturity="mature"
    elif [[ "$count" -ge 3 ]]; then
        maturity="standard"
    elif [[ "$count" -ge 1 ]]; then
        maturity="minimal"
    fi
    [[ "$count" -gt 0 ]] && reason="${count} CI workflow file(s)"

    local types_json
    types_json=$(printf '%s' "$types" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')

    jq -n \
        --argjson has_ci "$([[ "$count" -gt 0 ]] && echo true || echo false)" \
        --argjson ci_types "$types_json" \
        --argjson count "$count" \
        --arg maturity "$maturity" \
        --arg reason "$reason" \
        '{has_ci:$has_ci, ci_types:$ci_types, workflow_count:$count,
          maturity:$maturity, reason:$reason}'
}

# ─── detect_test_maturity ───────────────────────────────────────────────────
# {framework, maturity, has_coverage_config, test_ratio, test_file_count, reason}
#
# test_ratio is a FILE-COUNT PROXY, deliberately not called "coverage": it is
# not measured coverage and must never be reported as such.
detect_test_maturity() {
    local root="${1:-.}" framework="${2:-}" src_count="${3:-}" test_count="${4:-}"

    if [[ ! -d "$root" ]]; then
        jq -n --arg f "$framework" \
            '{framework:$f, maturity:"none", has_coverage_config:false,
              test_ratio:0, test_file_count:0, reason:"detection_skipped"}'
        return 0
    fi

    src_count=$(_sig_int "$src_count")
    test_count=$(_sig_int "$test_count")
    [[ -n "$src_count" ]]  || src_count=$(_sig_count_src_files "$root")
    [[ -n "$test_count" ]] || test_count=$(_sig_count_test_files "$root")
    src_count="${src_count:-0}"
    test_count="${test_count:-0}"

    local ratio=0
    [[ "$src_count" -gt 0 ]] && ratio=$(( test_count * 100 / src_count ))
    [[ "$ratio" -gt 100 ]] && ratio=100

    local has_cov=false
    if [[ -f "$root/codecov.yml" || -f "$root/.codecov.yml" || -f "$root/.coveragerc" || \
          -f "$root/.nycrc" || -f "$root/.nycrc.json" ]]; then
        has_cov=true
    elif grep -rlq --include='vitest.config.*' --include='jest.config.*' \
                   --include='pyproject.toml' --include='setup.cfg' \
                   -e 'coverage' -e 'collectCoverage' "$root" 2>/dev/null; then
        has_cov=true
    fi

    local maturity reason
    if [[ "$test_count" -eq 0 ]]; then
        maturity="none"
        reason="no test files found"
    elif [[ "$ratio" -lt 20 ]]; then
        maturity="new"
        reason="${test_count} test file(s), ${ratio}% of sources"
    elif [[ "$ratio" -lt 50 ]]; then
        maturity="established"
        reason="${test_count} test file(s), ${ratio}% of sources"
    else
        maturity="mature"
        reason="${test_count} test file(s), ${ratio}% of sources"
    fi
    # A configured coverage gate is evidence of intent that a raw file ratio
    # misses — it lifts a project one step, never past "mature".
    if [[ "$has_cov" == "true" && "$maturity" == "new" ]]; then
        maturity="established"
        reason="${reason}, coverage configured"
    fi

    jq -n \
        --arg f "$framework" \
        --arg m "$maturity" \
        --argjson cov "$has_cov" \
        --argjson ratio "$ratio" \
        --argjson tc "$test_count" \
        --arg reason "$reason" \
        '{framework:$f, maturity:$m, has_coverage_config:$cov,
          test_ratio:$ratio, test_file_count:$tc, reason:$reason}'
}

# ─── detect_repo_size ───────────────────────────────────────────────────────
# {commit_count, file_count, size_category, reason}
#
# A shallow clone (the CI checkout default) reports one commit. That must map
# to "unknown", never "tiny" — otherwise every CI-run prep sees a toy repo.
detect_repo_size() {
    local root="${1:-.}" src_count="${2:-}"

    if [[ ! -d "$root" ]]; then
        jq -n '{commit_count:-1, file_count:0, size_category:"unknown", reason:"detection_skipped"}'
        return 0
    fi

    src_count=$(_sig_int "$src_count")
    [[ -n "$src_count" ]] || src_count=$(_sig_count_src_files "$root")
    src_count="${src_count:-0}"

    local commits=-1 category="unknown" reason="detection_skipped"

    if _sig_bounded git -C "$root" rev-parse --is-inside-work-tree | grep -q true; then
        local shallow
        shallow=$(_sig_bounded git -C "$root" rev-parse --is-shallow-repository)
        if [[ "$shallow" == "true" ]]; then
            reason="shallow clone — commit history unavailable"
        else
            local raw
            raw=$(_sig_bounded git -C "$root" rev-list --count HEAD | tr -d ' ')
            raw=$(_sig_int "$raw")
            [[ -n "$raw" ]] && commits="$raw"
        fi
    else
        reason="not a git repository"
    fi

    if [[ "$commits" -ge 0 ]]; then
        if   [[ "$commits" -lt 100 ]];    then category="tiny"
        elif [[ "$commits" -lt 1000 ]];   then category="small"
        elif [[ "$commits" -lt 50000 ]];  then category="medium"
        elif [[ "$commits" -lt 500000 ]]; then category="large"
        else                                   category="massive"
        fi
        reason="${commits} commit(s), ${src_count} source file(s)"
    fi

    jq -n \
        --argjson commits "$commits" \
        --argjson files "$src_count" \
        --arg category "$category" \
        --arg reason "$reason" \
        '{commit_count:$commits, file_count:$files, size_category:$category, reason:$reason}'
}

# ─── detect_activity_level ──────────────────────────────────────────────────
# {is_active, days_since_last_commit, reason}
detect_activity_level() {
    local root="${1:-.}"

    if [[ ! -d "$root" ]]; then
        jq -n '{is_active:false, days_since_last_commit:-1, reason:"detection_skipped"}'
        return 0
    fi

    local last_ts days=-1
    last_ts=$(_sig_bounded git -C "$root" log -1 --format=%ct | tr -d ' ')
    last_ts=$(_sig_int "$last_ts")

    if [[ -n "$last_ts" ]]; then
        local now
        now=$(date +%s)
        days=$(( (now - last_ts) / 86400 ))
        [[ "$days" -lt 0 ]] && days=0
    fi

    local active=false reason="detection_skipped"
    if [[ "$days" -ge 0 ]]; then
        [[ "$days" -lt 30 ]] && active=true
        reason="last commit ${days} day(s) ago"
    fi

    jq -n \
        --argjson active "$active" \
        --argjson days "$days" \
        --arg reason "$reason" \
        '{is_active:$active, days_since_last_commit:$days, reason:$reason}'
}

# ─── project_collect_signals ────────────────────────────────────────────────
# Runs every detector and merges the fragments. One detector emitting garbage
# costs that key alone — the other four still reach the policy layer.
project_collect_signals() {
    local root="${1:-.}" framework="${2:-}" src_count="${3:-}" test_count="${4:-}"

    local mono ci tests size activity
    mono=$(detect_monorepo "$root" 2>/dev/null || true)
    ci=$(detect_ci_maturity "$root" 2>/dev/null || true)
    tests=$(detect_test_maturity "$root" "$framework" "$src_count" "$test_count" 2>/dev/null || true)
    size=$(detect_repo_size "$root" "$src_count" 2>/dev/null || true)
    activity=$(detect_activity_level "$root" 2>/dev/null || true)

    echo "$mono"     | jq -e . >/dev/null 2>&1 || mono='{}'
    echo "$ci"       | jq -e . >/dev/null 2>&1 || ci='{}'
    echo "$tests"    | jq -e . >/dev/null 2>&1 || tests='{}'
    echo "$size"     | jq -e . >/dev/null 2>&1 || size='{}'
    echo "$activity" | jq -e . >/dev/null 2>&1 || activity='{}'

    jq -n \
        --argjson monorepo "$mono" \
        --argjson ci "$ci" \
        --argjson test "$tests" \
        --argjson size "$size" \
        --argjson activity "$activity" \
        --arg collected_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{monorepo:$monorepo, ci:$ci, test:$test, size:$size,
          activity:$activity, collected_at:$collected_at}'
}
