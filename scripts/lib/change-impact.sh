#!/usr/bin/env bash
# change-impact.sh — Change Impact Analysis for Intelligent Stage Skipping
# Classifies git diff into buckets and answers whether a stage can be safely skipped.
# Source from pipeline-intelligence-skip.sh. Requires: git, jq.

[[ -n "${_CHANGE_IMPACT_LOADED:-}" ]] && return 0
_CHANGE_IMPACT_LOADED=1

VERSION="3.3.0"

# Defaults under set -u
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
BASE_BRANCH="${BASE_BRANCH:-main}"

# Hardcoded safety guard — these stages are NEVER skipped via change-impact
# (config cannot override this list).
CHANGE_IMPACT_NEVER_SKIP="intake build"

# Category → stages skip map (defaults; overridable via daemon-config.json)
_change_impact_default_skip_for() {
    case "$1" in
        docs)   echo "test compound_quality review spec_verification" ;;
        tests)  echo "deploy validate monitor" ;;
        config) echo "test deploy" ;;
        code)   echo "" ;;
        mixed)  echo "" ;;
        *)      echo "" ;;
    esac
}

# classify_change_impact [base_branch]
#   Reads `git diff --name-only <base>...HEAD`, buckets paths, writes
#   $ARTIFACTS_DIR/change-impact.json (atomic), prints category to stdout.
#   Always exits 0 — failures fail-open to "unknown".
classify_change_impact() {
    local base="${1:-$BASE_BRANCH}"
    local out="$ARTIFACTS_DIR/change-impact.json"
    local docs=0 tests=0 config=0 code=0 total=0
    local files="" category="unknown"

    mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || true

    # Resolve a diff target. Fall back through HEAD~1 → empty tree.
    if files=$(git diff --name-only "${base}...HEAD" 2>/dev/null); then
        :
    elif files=$(git diff --name-only HEAD~1 2>/dev/null); then
        :
    else
        files=""
    fi

    local file
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        total=$((total + 1))
        # Order matters: tests before generic code patterns.
        if [[ "$file" =~ (^|/)test_|[-_]test\.(sh|js|ts|py|go)$|\.test\.(js|ts|jsx|tsx)$|^tests?/ ]]; then
            tests=$((tests + 1))
        elif [[ "$file" =~ \.(md|rst|txt|adoc)$ ]] || [[ "$file" =~ ^docs/ ]] || [[ "$file" =~ ^(README|CHANGELOG|LICENSE) ]]; then
            docs=$((docs + 1))
        elif [[ "$file" =~ \.(json|ya?ml|toml|ini|cfg)$ ]] || [[ "$file" =~ ^\.github/ ]]; then
            config=$((config + 1))
        else
            code=$((code + 1))
        fi
    done <<< "$files"

    # Cap at safety ceiling — treat huge diffs as mixed (no skipping).
    if [[ "$total" -gt 5000 ]]; then
        category="mixed"
    elif [[ "$total" -eq 0 ]]; then
        category="unknown"
    elif [[ "$code" -gt 0 ]]; then
        # Any production code present → mixed if mixed with others, else code.
        if [[ "$docs" -gt 0 || "$tests" -gt 0 || "$config" -gt 0 ]]; then
            category="mixed"
        else
            category="code"
        fi
    elif [[ "$docs" -gt 0 && "$tests" -eq 0 && "$config" -eq 0 ]]; then
        category="docs"
    elif [[ "$tests" -gt 0 && "$docs" -eq 0 && "$config" -eq 0 ]]; then
        category="tests"
    elif [[ "$config" -gt 0 && "$docs" -eq 0 && "$tests" -eq 0 ]]; then
        category="config"
    else
        category="mixed"
    fi

    # Atomic write
    local tmp
    tmp=$(mktemp 2>/dev/null || echo "${out}.tmp.$$")
    jq -n \
        --arg category "$category" \
        --arg base "$base" \
        --argjson docs "$docs" \
        --argjson tests "$tests" \
        --argjson config "$config" \
        --argjson code "$code" \
        --argjson total "$total" \
        '{category:$category, base:$base,
          counts:{docs:$docs, tests:$tests, config:$config, code:$code, total:$total}}' \
        > "$tmp" 2>/dev/null \
        || echo "{\"category\":\"$category\",\"base\":\"$base\",\"counts\":{\"docs\":$docs,\"tests\":$tests,\"config\":$config,\"code\":$code,\"total\":$total}}" > "$tmp"
    mv "$tmp" "$out" 2>/dev/null || rm -f "$tmp"

    echo "$category"
    return 0
}

# change_impact_should_skip <stage>
#   Prints skip reason + returns 0 if stage should be skipped, else returns 1.
#   Honors SW_NO_SKIP=1 kill switch and hardcoded never_skip list.
change_impact_should_skip() {
    local stage="$1"
    [[ -z "$stage" ]] && return 1

    # Kill switch
    if [[ "${SW_NO_SKIP:-0}" == "1" ]]; then
        return 1
    fi

    # Hardcoded guard — config cannot override
    case " $CHANGE_IMPACT_NEVER_SKIP " in
        *" $stage "*) return 1 ;;
    esac

    # Read existing classification or compute on demand.
    local impact_file="$ARTIFACTS_DIR/change-impact.json"
    local category counts_code
    if [[ -f "$impact_file" ]] && jq empty "$impact_file" 2>/dev/null; then
        category=$(jq -r '.category // "unknown"' "$impact_file" 2>/dev/null) || category="unknown"
        counts_code=$(jq -r '.counts.code // 0' "$impact_file" 2>/dev/null) || counts_code=0
    else
        category=$(classify_change_impact "${BASE_BRANCH}" 2>/dev/null) || category="unknown"
        counts_code=$(jq -r '.counts.code // 0' "$impact_file" 2>/dev/null) || counts_code=0
    fi

    # Defensive: if any production code changed, only skip docs-stage-type stuff.
    # We never skip based on category when code count > 0 and category is not a pure bucket.
    [[ "$category" == "unknown" ]] && return 1
    [[ "$category" == "code" || "$category" == "mixed" ]] && return 1

    # Look up rule from daemon-config.json if present, else defaults
    local daemon_config=".claude/daemon-config.json"
    local rule_stages=""
    if [[ -f "$daemon_config" ]] && jq empty "$daemon_config" 2>/dev/null; then
        local enabled
        enabled=$(jq -r '.stage_skip_rules.enabled // true' "$daemon_config" 2>/dev/null) || enabled="true"
        [[ "$enabled" != "true" ]] && return 1
        rule_stages=$(jq -r --arg c "$category" '.stage_skip_rules.categories[$c].skip // [] | join(" ")' "$daemon_config" 2>/dev/null) || rule_stages=""
    fi
    [[ -z "$rule_stages" ]] && rule_stages=$(_change_impact_default_skip_for "$category")

    case " $rule_stages " in
        *" $stage "*)
            echo "change-impact:$category"
            return 0
            ;;
    esac
    return 1
}
